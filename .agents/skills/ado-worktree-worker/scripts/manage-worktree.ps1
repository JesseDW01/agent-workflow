param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("create", "remove", "list")]
    [string]$Action,

    [Parameter(Mandatory=$false)]
    [int]$WorkItemId,

    [Parameter(Mandatory=$false)]
    [string]$Slug = "task",

    [Parameter(Mandatory=$false)]
    [string]$BaseBranch = "main"
)

$ErrorActionPreference = "Stop"

$RepoRoot = (git rev-parse --show-toplevel).Trim()
$RepoName = Split-Path -Leaf $RepoRoot
$ParentDir = Split-Path -Parent $RepoRoot

if ($Action -eq "list") {
    git worktree list
    exit 0
}

if (-not $WorkItemId) {
    Write-Error "WorkItemId is required for 'create' and 'remove' actions."
}

$CleanSlug = ($Slug.ToLower() -replace '[^a-z0-9\-]', '-').Trim('-')
$BranchName = "feat/AB-$WorkItemId-$CleanSlug"
$WorktreePath = Join-Path $ParentDir "$RepoName-wt-ab-$WorkItemId"

if ($Action -eq "create") {
    Write-Host "Fetching latest from origin..."
    git fetch origin $BaseBranch 2>$null

    if (Test-Path $WorktreePath) {
        Write-Host "Worktree already exists at $WorktreePath"
    } else {
        $BranchExists = git branch --list $BranchName
        if ($BranchExists) {
            git worktree add $WorktreePath $BranchName
        } else {
            git worktree add -b $BranchName $WorktreePath "origin/$BaseBranch" 2>$null
            if ($LASTEXITCODE -ne 0) {
                git worktree add -b $BranchName $WorktreePath $BaseBranch
            }
        }
    }

    # Copy .env.example to .env if needed
    $EnvExample = Join-Path $WorktreePath ".env.example"
    $EnvTarget = Join-Path $WorktreePath ".env"
    if ((Test-Path $EnvExample) -and -not (Test-Path $EnvTarget)) {
        Copy-Item $EnvExample $EnvTarget
        Write-Host "Bootstrapped .env from .env.example"
    }

    $AssignedPort = 4000 + ($WorkItemId % 1000)
    Write-Host "READY_WORKTREE_PATH=$WorktreePath"
    Write-Host "READY_BRANCH=$BranchName"
    Write-Host "ASSIGNED_PORT_OFFSET=$AssignedPort"
    exit 0
}

if ($Action -eq "remove") {
    if (Test-Path $WorktreePath) {
        git worktree remove --force $WorktreePath
        Write-Host "Removed worktree at $WorktreePath"
    }
    git worktree prune
    exit 0
}
