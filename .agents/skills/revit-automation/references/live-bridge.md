# Channel A — Live bridge (Python in the running Revit session)

`bridge/AgentBridge.extension/startup.py` registers pyRevit Routes endpoints inside the open Revit. `scripts/revit_bridge.py` (CPython 3, stdlib only) is the client. Each request runs on Revit's **main thread via an ExternalEvent**, so you get the same API context as a button click: the real `uidoc`, the active view, the user's selection, and changes the user sees immediately.

## Contract

| Item | Value |
|---|---|
| Engine | **IronPython 2.7** (pyRevit default). No f-strings. Use `.format()` or `%` formatting. PY2/PY3-safe code only. |
| Namespace | `uiapp`, `app` (Application), `uidoc`, `doc` (active document, or `None` on the Home screen), `DB`, `UI`, `Tx`, `args`, `result`, `failures` |
| Return data | Assign to `result`. Element/ElementId/XYZ/lists/dicts are auto-converted to JSON. `print()` output comes back in `stdout`. |
| Persistence | The namespace **persists between calls** (REPL style), so helpers and variables defined earlier stay available. Pass `--fresh` to reset it. `uidoc`/`doc` are refreshed on every call. |
| Transactions | There is **no transaction by default**. Use `--tx "Name"` to wrap the whole run (commit on success, roll back on exception). Use `--tx X --rollback` for a **dry run**. Inside code, use `with Tx("Name"):` for several steps. Both attach a failures preprocessor that **deletes warnings and rolls back on errors instead of showing a modal dialog**. A bare `DB.Transaction` works too, but its warnings can pop dialogs. |
| Undo | Each committed transaction is one Ctrl+Z step for the user. To make a multi-step operation a single undo, wrap it in a `DB.TransactionGroup(doc, name)` → `Start()` … `Assimilate()`. |
| Timeout | The client defaults to 300 s. **A timeout does NOT cancel anything.** The event stays queued and runs as soon as Revit is idle. Re-check the model before you re-send modifying code. |
| Blocking | Requests are queued while Revit is busy, in an edit mode (sketch, a running command), or showing a modal dialog. If a ping hangs, ask the user to press Esc or close dialogs. |
| Security | Every request needs the token in `%APPDATA%\pyRevit\agent_bridge_token.txt` (created on first load). The server binds through pyRevit Routes. Check that it listens on localhost only with `netstat -ano \| findstr 4888`. |

## CLI

```bash
B="D:/GIT/agent-workflow/.agents/skills/revit-automation/scripts/revit_bridge.py"
python "$B" ping                                   # Revit version, active doc/view, open docs
python "$B" exec -c "result = [v.Name for v in DB.FilteredElementCollector(doc).OfClass(DB.ViewPlan)]"
python "$B" exec work.py --tx "Add walls"          # file, wrapped in a transaction
python "$B" exec work.py --tx "Probe" --rollback   # dry run: execute, report, roll back
python "$B" exec work.py --args '{"level":"Level 1"}'
python "$B" exec --raw -c "print(doc.Title)"       # plain stdout instead of JSON
python "$B" snapshot C:/path/out.png [--view "3D"] # PNG of a view -> then Read it to SEE the model
```

Write multi-line code to a scratch `.py` file and pass the path. Shell-quoting Python with `-c` is fragile.

## "Anything a human can do": recipes

```python
from System.Collections.Generic import List
mm = lambda v: DB.UnitUtils.ConvertToInternalUnits(v, DB.UnitTypeId.Millimeters)   # internal = feet

# --- Selection (what the user has selected / select for them)
sel = [doc.GetElement(i) for i in uidoc.Selection.GetElementIds()]
uidoc.Selection.SetElementIds(List[DB.ElementId]([e.Id for e in sel]))
uidoc.ShowElements(List[DB.ElementId]([eid]))                 # zoom to elements

# --- Ask the user to click something (request waits until they click / Esc)
from Autodesk.Revit.UI.Selection import ObjectType
ref = uidoc.Selection.PickObject(ObjectType.Element, "Pick a wall for the agent")
pt  = uidoc.Selection.PickPoint("Click insertion point")

# --- Views: switch, open, zoom
v = next(x for x in DB.FilteredElementCollector(doc).OfClass(DB.View) if x.Name == "Level 1" and not x.IsTemplate)
uidoc.ActiveView = v                       # NOT inside a transaction; fallback: uidoc.RequestViewChange(v)
for uv in uidoc.GetOpenUIViews():
    if uv.ViewId == v.Id: uv.ZoomToFit()

# --- Documents
uiapp.OpenAndActivateDocument(r"D:\path\model.rvt")   # visible in UI; fallback app.OpenDocumentFile (background)
doc.Save()                                            # outside any transaction
# Synchronize (workshared): doc.SynchronizeWithCentral(DB.TransactWithCentralOptions(), DB.SynchronizeWithCentralOptions())

# --- Run ANY ribbon command, exactly like clicking it (fires AFTER this request returns, one per request)
uiapp.PostCommand(UI.RevitCommandId.LookupPostableCommandId(UI.PostableCommand.Wall))
# Non-postable/add-in commands: UI.RevitCommandId.LookupCommandId("ID_OBJECTS_WALL")  (journal IDs)

# --- Create / modify (use --tx or Tx)
lvl = next(l for l in DB.FilteredElementCollector(doc).OfClass(DB.Level) if l.Name == "Level 1")
with Tx("Agent: wall"):
    w = DB.Wall.Create(doc, DB.Line.CreateBound(DB.XYZ(0,0,0), DB.XYZ(mm(5000),0,0)), lvl.Id, False)
    w.get_Parameter(DB.BuiltInParameter.ALL_MODEL_INSTANCE_COMMENTS).Set("made by agent")
result = w

# --- Parameters (read like the Properties palette)
result = dict((p.Definition.Name, p.AsValueString() or p.AsString()) for p in elem.Parameters)

# --- Load family / place instance
with Tx("Load + place"):
    ok, fam = doc.LoadFamily(r"D:\path\Thing.rfa")   # IronPython returns out-params as a tuple
    # ok == False -> already loaded: find it via FilteredElementCollector(doc).OfClass(DB.Family)
    sym = doc.GetElement(list(fam.GetFamilySymbolIds())[0])
    if not sym.IsActive: sym.Activate()
    doc.Create.NewFamilyInstance(DB.XYZ(0,0,0), sym, lvl, DB.Structure.StructuralType.NonStructural)

# --- Export (PDF/DWG/IFC/images)
opts = DB.PDFExportOptions(); opts.FileName = "out"; opts.Combine = True
doc.Export(r"C:\out", List[DB.ElementId]([sheet.Id]), opts)
```

## Seeing the result (visual verification loop)

1. Make the change, and return ids and counts in `result`.
2. Run `python revit_bridge.py snapshot <scratch>/after.png --view "<view>"`, then **Read the PNG** to check it visually, the way a human would look at the screen.
3. Before any snapshot or desk check, read values back with a separate `exec`. Don't trust the write call alone.

## Gotchas

- **Never open a modal UI** from bridge code (`forms.alert`, `TaskDialog.Show`, `forms.SelectFromList`). It blocks Revit until a human closes it, and every later request hangs. To report something, use `print`/`result`.
- `PostCommand` runs *after* your code returns, and only the last posted command counts. Don't expect its effect inside the same request.
- Setting `uidoc.ActiveView`, `doc.Save()`, `OpenAndActivateDocument`, `ExportImage` and `doc.Export` must happen **outside** transactions, so don't use `--tx` for those calls.
- Long loops freeze the Revit UI while they run. Process in batches of a few thousand elements per request.
- The persistent namespace can hold stale `Element` objects after an undo or document switch. Re-fetch by id.
- After editing `startup.py`, use pyRevit tab → **Reload**, or restart Revit. The bridge re-registers its routes.
- Routes server not running: `pyrevit configs routes` shows Disabled. Run `pyrevit configs routes enable`, then restart Revit. In the pyRevit log, look for "Error starting Routes server" (port in use).
