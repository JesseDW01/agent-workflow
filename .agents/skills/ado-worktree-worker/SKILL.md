---
name: ado-worktree-worker
description: >-
  Use this skill when acting as an implementation Worker Agent assigned to an Azure DevOps
  Work Item. Manages isolated git worktree creation, port/env isolation, Test-Driven Development
  (TDD), Azure Repos branch push, Pull Request creation/linking, and PR review rework.
type: prompt
whenToUse: >-
  When implementing an Azure DevOps work item (AB#id) in an isolated git worktree, opening an
  Azure Repos Pull Request, or addressing PR review rework comments.
---

# Azure DevOps Worktree Implementation Worker (`ado-worktree-worker`)

You are an isolated **Worker Agent** executing a single Azure DevOps Work Item (`AB#<WorkItemId>`). You operate in a dedicated Git worktree so your file edits, builds, and tests never collide with parallel workers.

---

## 1. Workspace & Worktree Isolation

1. **Check Current Workspace:**
   - If you were spawned in an isolated Herdr worktree space (`HERDR_ENV=1` on branch `feat/AB-<WorkItemId>-<slug>`) or with Antigravity `Workspace: "share"`, you are already in an isolated working copy—verify or checkout the feature branch directly:
     ```bash
     git fetch origin
     git checkout -B feat/AB-<WorkItemId>-<slug> origin/<TargetBranch>
     ```
   - Otherwise, create a dedicated sibling Git worktree:
     - **Windows (PowerShell):**
       ```powershell
       powershell -ExecutionPolicy Bypass -File .\.agents\skills\ado-worktree-worker\scripts\manage-worktree.ps1 -Action create -WorkItemId <WorkItemId> -Slug "<slug>" -BaseBranch "<TargetBranch>"
       ```
     - **Linux / SSH Host (e.g. `devs7`):**
       ```bash
       ./.agents/skills/ado-worktree-worker/scripts/manage-worktree.sh create <WorkItemId> "<slug>" "<TargetBranch>"
       ```
   - Perform **all** file reads, edits, builds, and test executions strictly inside that worktree path.
2. **Environment & Port Isolation:**
   - If starting any local dev or test server, calculate an isolated port: `$Port = 4000 + (<WorkItemId> % 1000)`. Never bind to shared default ports (`3000`, `5000`, `8080`) without an offset.

---

## 1b. Board Tracking (MANDATORY — the user follows your progress on the sprint taskboard)

Move the cards **while you work**, not in one batch at the end. Use the shared helper:
```powershell
$board = "$HOME\.agents\skills\ado-backlog-orchestrator\scripts\ado-board.ps1"
$a = @{ Org = '<Org>'; Project = '<Project>'; Team = '<Team>' }
& $board -Action current @a   # prints the sprint path; if it fails, ask the orchestrator (it runs -Action ensure)
```

1. **On start:** make sure the PBI/Bug and all child Tasks are in the current sprint and the PBI is `Committed` (Agile: `Active`) with tag `agent-working`:
   ```powershell
   & $board -Action assign @a -Id <WorkItemId> -WithChildren
   & $board -Action move   @a -Id <WorkItemId> -State Committed -AddTags agent-working -Comment "Started by <worker> on feat/AB-<id>-<slug>"
   ```
2. **Before starting each Task:** `& $board -Action move @a -Id <taskId> -State "In Progress" -Remaining <hours> -Activity Development` (use `Testing`/`Documentation` where appropriate). Only the Task(s) you are actually working on are `In Progress`.
3. **When a Task is finished** (tests green, committed): `& $board -Action move @a -Id <taskId> -State Done -Comment "Done in <sha>: <one line>"` (sets `RemainingWork` 0).
4. **Discovered work** that is out of scope: create a new Task under the PBI (or a follow-up PBI under the Feature) in the current sprint, state `To Do`/`New` — never silently skip it.
5. **Blocked:** keep the Task `In Progress`, add tag `blocked` to the PBI and a comment saying exactly what is needed.
6. **Never** set the PBI to `Done` yourself — the reviewer does that after merge. Never leave a Task `To Do` that you have actually completed.

---

## 2. Implementation Workflow (New Feature / Bug)

Follow strict **Red-Green-Refactor Test-Driven Development** (adapted from `obra/superpowers`):

1. **Baseline Verification:**
   - Run the existing test suite inside the worktree before making changes to confirm a green baseline.
2. **Write Failing Tests (Red):**
   - Translate every bullet point in the Azure DevOps `AcceptanceCriteria` into automated unit or integration tests.
   - Run the tests and confirm they fail for the expected reason.
3. **Minimal Implementation (Green):**
   - Write the clean, minimal production code required to satisfy the tests and acceptance criteria.
   - Do **not** gold-plate or refactor unrelated files outside the work item scope (prevent merge conflicts with parallel workers).
4. **Refactor & Full Verification:**
   - Run the full test suite, linter, and typechecker. All checks must pass with zero errors.

---

## 3. Rework Workflow (When Dispatched on `changes-requested`)

If your brief includes a `PullRequestId` and unresolved review threads:
1. Checkout the existing branch `feat/AB-<WorkItemId>-<slug>` in your worktree and pull latest changes.
2. Address each blocking review thread methodically:
   - Add a regression test reproducing the issue raised by the reviewer.
   - Implement the fix and re-run the full test suite.
3. Reply to each resolved review thread on the Pull Request via MCP (`repo_create_pull_request_thread_comment` or `az repos pr`) explaining the fix and commit SHA, and mark the thread status as `Fixed` (`2`).

---

## 4. Commit, Push & Pull Request Delivery

1. **Stage & Commit:**
   - Verify `git status` contains no untracked temporary/scratch files.
   - Commit using conventional commits with the Azure Boards work item link trailer:
     ```powershell
     git commit -m "feat(<scope>): <concise summary> (AB#<WorkItemId>)" -m "Implements AB#<WorkItemId>"
     ```
2. **Push Branch:**
   ```powershell
   git push -u origin feat/AB-<WorkItemId>-<slug>
   ```
3. **Create or Update Pull Request in Azure Repos:**
   - If no open PR exists for `feat/AB-<WorkItemId>-<slug>` → `<TargetBranch>`, create one via MCP (`repo_create_pull_request`) or `az repos pr create`:
     - **Title:** `[AB#<WorkItemId>] <Work Item Title>`
     - **Description:** Summarize what was implemented, how each Acceptance Criterion was verified, and link `AB#<WorkItemId>`.
     - **Work Item Link:** Explicitly link `WorkItemId` to the PR.
4. **Update Work Item State:**
   - Keep the PBI `Committed` (Agile: `Resolved`/`In Review`), remove tag `changes-requested` if present, add tag `pr-open`, and comment with the PR link (`move -AddTags pr-open -RemoveTags changes-requested -Comment "PR !<id> opened"`).
   - Every Task you completed must already be `Done`; any Task you could not finish stays `In Progress` with honest `RemainingWork` and is listed in the PR description.

---

## 5. Worker Return Contract

Report back to the Orchestrator with a concise structured block (note: the Reviewer Agent will **not** see this block, only the Orchestrator):
- `WorkItemId`: `AB#<id>`
- `WorktreePath`: `<absolute path>`
- `Branch`: `feat/AB-<id>-<slug>`
- `PullRequestId`: `<PR ID>`
- `VerificationSummary`: Exact test commands run and pass counts.
- `BoardState`: each Task ID with its final state (must match the board).
