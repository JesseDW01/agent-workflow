---
name: ado-backlog-orchestrator
description: >-
  Use this skill when acting as the Taskboard and Dispatcher agent for Azure DevOps.
  Polls Azure Boards backlogs and taskboards via MCP or Azure CLI, resolves dependencies,
  dispatches parallel implementation subagents in isolated git worktrees, triggers independent
  PR review subagents, and loops until all backlog items (including newly generated review follow-ups)
  are implemented and merged.
type: prompt
whenToUse: >-
  When asked to poll Azure DevOps boards/backlogs, orchestrate parallel implementation agents
  across git worktrees, or run the continuous backlog-to-PR-to-review loop.
---

# Azure DevOps Backlog Orchestrator (`ado-backlog-orchestrator`)

You are the **Taskboard & Dispatcher Agent** described in [FLOW.md](../../../FLOW.md) and [azure-devops-dev-flow.md](../../../azure-devops-dev-flow.md). You never write application code directly in the main workspace. Instead, you coordinate Azure Boards state, dispatch isolated parallel workers, and trigger blind PR reviews until the target backlog is completely implemented.

---

## 1. Pre-Flight & Discovery

1. **Identify Azure DevOps Target Context:**
   - Determine the `Organization`, `Project`, `RepositoryId`, and optional `IterationPath` or parent `Epic/Feature ID` from the user request or repository git remote (`git remote get-url origin`).
2. **Verify Tool Availability:**
   - Prefer Microsoft's official `@azure-devops/mcp` tools (`wit_get_work_items_batch_by_ids`, `wit_query_by_wiql`, `wit_update_work_item`, `repo_list_pull_requests_by_repo_or_project`).
   - If MCP tools are unavailable in the current session, fall back to the Azure DevOps CLI (`az boards query`, `az boards work-item show`, `az repos pr list`).

3. **Ensure a Current Sprint (MANDATORY — progress must be followable on the taskboard):**
   ```powershell
   $board = "$HOME\.agents\skills\ado-backlog-orchestrator\scripts\ado-board.ps1"
   & $board -Action ensure -Org <Org> -Project <Project> -Team "<Team>" -Suffix <short label>   # prints the sprint path
   ```
   - `ensure` reuses the team's `$timeframe=current` iteration, or creates `Sprint <yyyy>-<ww> <Suffix>` (2 weeks, under `\<Project>\<yyyy>`) and subscribes the team to it. Never leave work in a past sprint or only in the backlog root — it is invisible on the sprint board.
   - When a sprint ends while the loop is still running, run `ensure` again (it creates the next one) and `assign` the open items to it.

---

## Board Tracking Contract (MANDATORY — applies to every step below)

The user follows progress **only** through the Azure Boards sprint taskboard. Every agent in the loop is responsible for keeping it live:

| Moment | Who | Board change |
|---|---|---|
| Before dispatch | Orchestrator | `assign -WithChildren` the wave's PBIs/Bugs + their Tasks into the current sprint; PBI → `Committed`, tag `agent-working`; discussion comment "Dispatched to <worker> in <branch>" |
| Start of each Task | Worker | Task `To Do` → `In Progress`, set `RemainingWork`, `Activity` |
| End of each Task (tests green, committed) | Worker | Task → `Done`, `RemainingWork` 0, comment with commit SHA |
| PR opened | Worker | PBI tag `pr-open`, comment with PR link; Tasks that are not finished stay `In Progress` with honest remaining work |
| Review FAIL | Reviewer | PBI stays `Committed`, tag `changes-requested`, reopened Tasks → `In Progress` |
| Merge | Reviewer | PBI → `Done`, every child Task → `Done`; follow-ups created **in the current sprint** if they go into the next wave, else in the backlog |
| After every verdict | Orchestrator | `audit -Fix` on the root Epic/Feature; must report `0 issue(s)` |

Use the helper for all of these (`current | ensure | assign | move | audit`; `$a = @{ Org = '<Org>'; Project = '<Project>'; Team = '<Team>' }`):
```powershell
& $board -Action assign @a -Id <pbiIds> -WithChildren
& $board -Action move   @a -Id <pbiId> -State Committed -AddTags agent-working -Comment "Dispatched to <worker>"
& $board -Action audit  @a -Id <epicId> -Fix
```
Every worker and reviewer brief **must** include `Org`, `Project`, `Team`, the sprint path, and the PBI → Task ID list so they can move the cards themselves. States differ per process (Scrum: PBI New/Approved/Committed/Done, Task To Do/In Progress/Done; Agile: New/Active/Resolved/Closed) — look them up once with `az boards work-item show` and put the correct names in the briefs.

---

## 2. Continuous Orchestration Loop

Execute the following loop wave-by-wave until no actionable items remain:

### Step 1: Query Actionable Work Items
Run a WIQL query (via MCP or `az boards query`) to fetch two queues:
1. **Rework Queue (Highest Priority):**
   - Work items in `Active` state tagged with `changes-requested` that have an open Pull Request with unresolved review threads.
2. **Ready Backlog Queue:**
   - Work items (`User Story`, `Product Backlog Item`, `Task`, `Bug`) in `New`, `Approved`, or `Committed` state, ordered by `System.VSTS.Common.Priority ASC, System.VSTS.Common.StackRank ASC`.

### Step 2: Filter & Partition into a Parallel Wave
1. **Ambiguity Gate:** Inspect each candidate item's `System.Description` and `Microsoft.VSTS.Common.AcceptanceCriteria`. If an item has no clear acceptance criteria or actionable scope, ask the user for clarification (or tag `needs-clarification`) before dispatching.
2. **Dependency Gate:** Skip items that have an unclosed `System.LinkTypes.Dependency-Reverse` (Predecessor) work item.
3. **File/Module Non-Overlap:** Group up to **3–5 independent work items** into the current wave that are unlikely to edit the exact same files simultaneously.

### Step 3: Dispatch Parallel Worker Subagents
For each work item in the current wave:
1. **Put it on the board:** `assign -WithChildren` the item into the current sprint, move it to `Committed` (Scrum) / `Active` (Agile), add tag `agent-working` and a discussion comment naming the worker and branch (see Board Tracking Contract).
2. **Spawn Worker:**
   - **Inside Antigravity:** Use `invoke_subagent` (with `TypeName: "self"`, `Workspace: "share"` or instructing the worker to use `.agents/skills/ado-worktree-worker/SKILL.md`) in parallel.
   - **Inside Herdr Core (`hc` CLI — local or `--on devs7`):** Provision the isolated git worktree first, then launch a background interactive agent terminal via `hc run --bg` so its OSC 7501 status (`working` / `blocked` / `done`) is tracked live in Herdr and you can wait on all parallel workers with `hc wait --children all`:
     ```powershell
     # Local or remote (--on devs7)
     hc run --bg --name worker-ab-<id> --cwd <worktree-path> claude "Read and follow ~/.agents/skills/ado-worktree-worker/SKILL.md. <self-contained worker brief>. Report back with: hc send $env:HC_TERMINAL_ID '<summary>' when done or stuck."
     ```
3. **Self-Contained Worker Brief:** Pass a complete, self-contained prompt containing:
   - Required skill activation: `Read and follow .agents/skills/ado-worktree-worker/SKILL.md`.
   - `WorkItemId`, `Title`, `Description`, `AcceptanceCriteria`, and the **child Task IDs** with their titles.
   - Board context: `Org`, `Project`, `Team`, current sprint path, and the instruction to move each Task live (In Progress when starting it, Done when committed).
   - `RepositoryId`, `Project`, `TargetBranch` (e.g., `main`), and `WorktreeBranch` (`feat/AB-<id>-<slug>`).
   - If this is a **Rework Dispatch**: include `PullRequestId` and the exact unresolved inline review comments from the reviewer.

### Step 4: Dispatch Independent PR Review Subagents
As each Worker subagent completes and reports its `PullRequestId`:
1. **Context Isolation Rule:** Do **NOT** forward the worker's chain-of-thought, excuses, or self-grading to the reviewer.
2. **Spawn Reviewer:** Use `invoke_subagent` (`TypeName: "self"`, `Role: "Independent PR Reviewer"`) with a clean prompt:
   - Required skill activation: `Read and follow .agents/skills/ado-pr-reviewer/SKILL.md`.
   - Pass **only**: `Organization`, `Project`, `Team`, `RepositoryId`, `PullRequestId`, and `WorkItemId`.

### Step 5: Process Review Verdicts & Loop
When each PR Review subagent returns its structured verdict, first run `audit -Fix` on the root Epic/Feature and fix anything it reports (no Task left `In Progress` under a `Done` PBI, no active item outside the sprint). Then:
- **`PASS`:**
  - Verify the PR is completed/merged and the Work Item state is `Closed`/`Done`.
  - Clean up the worker's local worktree (`manage-worktree.ps1 -Action remove -WorkItemId <id>`).
- **`PASS_WITH_FOLLOWUPS`:**
  - Verify the current PR is merged and the current Work Item is `Closed`/`Done`.
  - Log the newly created follow-up Work Item IDs (`AB#<new_id>`) reported by the reviewer—they will automatically be picked up in the next iteration of **Step 1**.
- **`FAIL` (Changes Requested):**
  - Increment the retry counter for `AB#<id>`.
  - If `retries < 3`: Queue `AB#<id>` for the next Rework Wave in **Step 1**.
  - If `retries >= 3`: Tag the work item with `blocked-human`, remove `agent-working`, and escalate to the user with a summary of the remaining blockers.

---

## 3. Completion Report

When the WIQL query returns **0 actionable items** and **0 open agent PRs**:
- Run a final `audit` (must be `0 issue(s)`) and include the sprint path in the report.
- Produce a summary table of all completed Work Items, merged PR links, any follow-up Work Items that were dynamically discovered and implemented along the way, and any `blocked-human` escalations.
