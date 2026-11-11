---
name: revit-automation
description: >-
  Drive Autodesk Revit (2027, pyRevit 6.x) like a human would, from an agent: read and modify the model,
  select, switch views, run ribbon commands, create walls, families, materials and schedules, export, and
  screenshot views to verify visually. Three channels: (A) live Python in the running Revit via the
  pyRevit Routes Agent Bridge, (B) the revit MCP's C# send_code_to_revit, (C) headless `pyrevit run`.
  Includes verified Revit 2027 API facts (ElementId.Value, Ellipse.CreateCurve, NewRevolution, schedule
  and material-takeoff recipes, phase filters, FamilyManager, appearance assets, shared parameters).
  USE FOR: revit, pyrevit, revitpy, revit api, revit python, rvt, rfa, family creation, schedule,
  material takeoff, revit mcp, send code to revit, pyrevit run, pyrevit extension, BIM automation.
  DO NOT USE FOR: Dynamo graphs, standalone C# add-in projects, IFC-only work without Revit.
type: prompt
whenToUse: >-
  Whenever the task touches an Autodesk Revit model (.rvt), family (.rfa), or the Revit/pyRevit API, or
  the user asks the agent to "do something in Revit".
metadata:
  version: "2.0.0"
  origin: "Merged from opencode skills revit-api-automation 1.0.0 + pyrevit-automation 1.3.0, plus new live bridge"
---

# Revit Automation

Goal: do in Revit anything a human can do, scripted, with every change verified. The knowledge here was **verified empirically on Revit 2027 + pyRevit 6.5.3**. Where it conflicts with your training data, trust it. Revit 2027 renamed and removed several APIs.

## 1. Pick the channel

| Situation | Channel | Speed | Language |
|---|---|---|---|
| Revit is open and the user is working in it (default) | **A. Live bridge**: `scripts/revit_bridge.py` | ~0.1–2 s per call | IronPython 2.7 |
| Bridge not installed, but the revit MCP tools (`mcp__revit__*`) are available | **B. MCP C# executor** | seconds | C# snippet |
| Revit closed, batch over many files, or building .rfa families unattended | **C. Headless `pyrevit run`** | 1–5 min per run, flaky | IronPython 2.7 |

Start every session with `python <skill>/scripts/revit_bridge.py ping`:
- `ok: true`: use Channel A. Read **`references/live-bridge.md`**.
- Exit 2 (unreachable): check `tasklist | findstr Revit`. If Revit is running, the bridge is probably not installed or not enabled. Offer `scripts/install_bridge.ps1` (needs a Revit restart). Otherwise use B or C.
- Channel B: read **`references/mcp-csharp.md`**. Its executor contract differs: you must NOT open transactions there.
- Channel C: read **`references/pyrevit-headless.md`**. It also holds the deep knowledge on families, FamilyManager, materials, appearance assets, shared parameters and schedules, which applies to every channel.

## 2. Setup (one-time per machine)

- **Bridge (A):** `powershell -File <skill>/scripts/install_bridge.ps1`. It junctions `bridge/AgentBridge.extension` into `%USERPROFILE%\pyRevit`, then runs `pyrevit configs routes enable`. Restart Revit afterwards. A "Agent → Bridge Status" button appears in Revit. Uninstall with `-Uninstall`.
- **MCP (B), optional:** needs the `mcp-servers-for-revit` Revit add-in, plus `claude mcp add revit -s user -- npx -y mcp-server-for-revit`. The opencode equivalent is `"revit": {"type":"local","command":["npx","-y","mcp-server-for-revit"]}`.
- **pyRevit:** run `pyrevit env` to check it. For the Revit 2027 / .NET 10 install fix (DriveInfo), see `references/pyrevit-headless.md` §4.

## 3. Core rules (all channels)

1. **Probe before building.** Read the project state first: levels, views, types, phases, selection. When an API name fails, reflect on the runtime types (`clr.GetClrType(DB.X).GetMethods()` in Python, `typeof(X).GetMethods()` in C#). Don't guess repeatedly.
2. **Revit 2027 API traps:** `ElementId.Value` (long). `.IntegerValue` was **removed**. `Ellipse.CreateCurve` (not CreateEllipse). `NewRevolution` takes a `Line` axis. `Material.Create` returns an ElementId. `OST_SpecialityEquipment` (British spelling). `GroupTypeId.Dimensions` does not exist.
3. **Units:** internal length is **feet**. Use `DB.UnitUtils.ConvertToInternalUnits(v, DB.UnitTypeId.Millimeters)`, or `mm/304.8`.
4. **Transactions:** model changes need one in A and C. The MCP (B) opens one for you, so never nest one there. View switching, saving, exporting and opening documents must happen outside transactions.
5. **No modal dialogs, ever.** An open dialog (yours or Revit's) blocks every channel. Swallow failure warnings through a failures preprocessor (the bridge's `Tx` / `--tx` does this). If something hangs, ask the user to close dialogs and press Esc.
6. **Verify like a human.** After a change, read values back in a separate call, and use `revit_bridge.py snapshot out.png --view ...` then Read the PNG to look at it. Cross-check numbers, like schedule totals, against independent computation.
7. **Be careful with the user's model.** Prefer `--rollback` dry runs for risky bulk edits. Use one named transaction per logical step so Ctrl+Z works. Never `doc.Save()`, sync, delete in bulk, or purge without the user agreeing. Don't run Channel C against a file that is open in the UI, and abort if `doc.IsWorkshared` unless the user asked.
8. **State known limits honestly**, with a manual workaround. Example: calculated-value schedule columns can't be created via the API (see mcp-csharp.md §6).
9. **OneDrive paths move between sessions.** Re-verify file paths before scripted runs.

## 4. Learning loop

When you discover a new verified fact (an API rename, a recipe, a pitfall), add it to the matching `references/*.md` in this repo (`D:\GIT\agent-workflow\.agents\skills\revit-automation`) with "verified 2027" and a one-line why. Keep facts empirical. Don't add generic API docs.
