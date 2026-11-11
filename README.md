# Agent Workflow

A self-improving, multi-agent workflow for everyday tasks.

The system is built around a **taskboard agent** that owns all projects and tasks,
**worker agents** that execute tasks, **independent feedback agents** that review and
deliver results over any channel (including voice), a **Q&A side-channel**, and a
**scheduled improvement agent** that watches the whole system and proposes better
skills, agents, and tools over time.

See [FLOW.md](FLOW.md) for the full v1 design, [azure-devops-dev-flow.md](azure-devops-dev-flow.md) for the concrete Azure DevOps + Git Worktree + PR Review multi-agent pipeline, and [docs/central-skill-management.md](docs/central-skill-management.md) for syncing skills across local Windows, Herdr, and remote SSH hosts (`devs7`).

## Principles

1. **One source of truth** — the taskboard agent owns all state. Everything else is a client of it.
2. **Workers don't grade their own homework** — feedback always comes from an agent that did
   not do the work.
3. **Feedback goes where you are** — messages, diagrams, live previews, voice notes, on any device.
4. **Questions don't interrupt work** — a separate Q&A channel answers without touching the worker.
5. **The system watches itself** — a scheduled monitor builds history and proposes improvements,
   which you approve before they go live.

## Repository layout (v1)

```
agent-workflow/
├── README.md                    # This file
├── FLOW.md                      # The full workflow design and agent specs
├── azure-devops-dev-flow.md     # Azure DevOps Boards/Repos + Worktree + PR Review flow
├── link-skills.ps1              # Links .agents/skills/* locally (Windows Junctions) & via SSH
├── link-skills.sh               # Links .agents/skills/* on Linux/macOS SSH hosts (devs7)
├── .agents/skills/              # Agent skills (Orchestrator, Worktree Worker, PR Reviewer)
│   ├── ado-backlog-orchestrator/
│   ├── ado-worktree-worker/
│   ├── ado-pr-reviewer/
│   ├── revit-automation/        # Drive Revit: live pyRevit bridge, revit MCP, headless pyrevit run
│   ├── freecad-automation/      # Drive FreeCAD via Python API / Robust MCP Bridge
│   └── sketchup/                # Drive SketchUp Pro via sketchup-mcp2 + Ruby API
└── docs/
    └── central-skill-management.md # Single-source-of-truth skill linking guide (Windows + devs7)
```
