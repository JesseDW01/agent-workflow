# Links all skills from this repository (.agents/skills/*) into the user-scope
# skill directories on Windows using Directory Junctions (no Admin required).
#
# Targets:
#   - ~/.agents/skills          (Universal Agent Skills / Herdr my-skills panel)
#   - ~/.kimi-code/skills       (Kimi Code CLI inside Herdr terminals)
#   - ~/.claude/skills          (Claude Code CLI inside Herdr terminals)
#   - ~/.gemini/config/skills.json (Antigravity global skill registry)
#
# Usage:
#   .\link-skills.ps1
#   .\link-skills.ps1 -RemoteHost devs7   # Also pulls & links on SSH host devs7

param(
    [string]$RemoteHost,
    [string]$RemoteRepoPath = "~/git/agent-workflow"
)

$ErrorActionPreference = "Stop"
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
    cmd /c "if not exist `"$TargetRoot`" mkdir `"$TargetRoot`""
    foreach ($Skill in $SkillFolders) {
        $LinkPath = Join-Path $TargetRoot $Skill.Name
        $SourceDir = Join-Path $SkillsSource $Skill.Name
        cmd /c "if exist `"$LinkPath`" rmdir `"$LinkPath`"" 2>$null
        cmd /c "mklink /J `"$LinkPath`" `"$SourceDir`"" | Out-Null
        Write-Host "[Windows] Linked $($Skill.Name) -> $LinkPath"
    }
}

# Register in Antigravity global skills.json (~/.gemini/config/skills.json)
$GeminiConfigDir = Join-Path $env:USERPROFILE ".gemini\config"
New-Item -ItemType Directory -Force -Path $GeminiConfigDir | Out-Null
$GeminiSkillsJson = Join-Path $GeminiConfigDir "skills.json"
$NormalizedPath = $SkillsSource -replace '\\', '/'

$ConfigObj = @{
    entries = @(
        @{ path = $NormalizedPath }
    )
}
$ConfigObj | ConvertTo-Json -Depth 5 | Set-Content -Path $GeminiSkillsJson -Encoding UTF8
Write-Host "[Windows] Registered $NormalizedPath in $GeminiSkillsJson"

if ($RemoteHost) {
    Write-Host "`nSyncing and linking skills on remote SSH host '$RemoteHost'..."
    $RemoteCmd = "if [ -d $RemoteRepoPath/.git ]; then git -C $RemoteRepoPath pull --ff-only; else mkdir -p `$(dirname $RemoteRepoPath) && git clone https://github.com/JesseDW01/agent-workflow.git $RemoteRepoPath; fi && bash $RemoteRepoPath/link-skills.sh"
    ssh $RemoteHost $RemoteCmd
}
