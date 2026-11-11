# Channel C — headless `pyrevit run`, extensions, families, materials

> Ported from the opencode `pyrevit-automation` skill (pyRevit 6.5.3 + Revit 2027, verified). Everything about the Revit API and IronPython here also applies to the live bridge (Channel A), EXCEPT the process mechanics of section 1.


## 1. Headless scripting: `pyrevit run` (use when Revit is NOT open, or for batch work on closed files)

`pyrevit run <script.py> --revit=2027` executes a script in Revit without any button. Prefer the live bridge (Channel A) whenever Revit is already open — it is seconds instead of minutes.

**Mechanics (observed):**
- It spawns a **separate headless Revit instance via journal replay** (PyRevitRunner addin + generated journal in `%TEMP%\<execution-guid>\`). It does NOT attach to the already-running Revit window.
- Each run takes 1–5 min (full Revit boot). Batch work into one script; avoid many small runs.
- **Flakiness: ~1 in 3 runs stalls** — the spawned instance dies right after `TabActivated:Add-Ins`, producing an empty "Execution Log" and no `PyRevitRunner_*.log`. Detection: CLI returns but no log file in the execution dir. **Fix: just retry.** Don't debug the script for this.
- One observed hard hang (10+ min, no script execution). Kill and retry.

**Script contract in `pyrevit run`:**
- `from pyrevit import HOST_APP` → **`HOST_APP.app` IS the `Application` object** (NOT UIApplication — `HOST_APP.app.Application` throws MissingMember).
- `print()` output appears in the CLI "Execution Log" section. The CLI output file is **UTF-16** — read with `Get-Content -Encoding Unicode`; a stray `?`/BOM char prefixes the first printed line.
- **Result-file pattern (do this always):** scripts should append status to a known text file AND delete it at start. If the run stalls or prints get lost, the file tells you how far execution got. Pattern: `report()` helper writing to both print and file.
- **Transactions: open your own** (`DB.Transaction(fam, 'name')` + Start/Commit). On failure you MUST `tx.RollBack()` before `fam.Close(False)` — Close with an open transaction throws "Close is not allowed when there is any open sub-transaction…" which then MASKS the original error (this cost a full iteration).

## 2. Verified Revit 2027 API facts (Family creation session)

All verified in Revit 2027 (27.0.4.412) via runtime reflection probes — several differ from training knowledge:

- **`Ellipse.CreateEllipse` does NOT exist.** Use `Ellipse.CreateCurve(center, xRadius, yRadius, xAxis, yAxis, startParam, endParam) -> Curve`.
- **Extrusion sketch loops need the ellipse split into TWO 180° arcs** (0→π, π→2π); a single closed ellipse curve is rejected.
- **`FamilyCreate.NewRevolution(solid, profile, sketchPlane, axis, startAngle, endAngle)` takes the axis as a `Line`** — the `Reference` overload is gone ("TypeError: expected Line, got Reference"). No need to draw a ModelLine for the axis anymore.
- **`ElementId.Value` (long) exists; `.IntegerValue` is REMOVED** in 2027 (breaks old snippets).
- `NurbSpline.CreateCurve(int degree, IList<double> knots, IList<XYZ> controlPoints)` works. Clamped-uniform knots: count = nCtrl + degree + 1; first/last degree+1 knots are 0/1; middle knots j/(mid+1) for j=1..mid where mid = count − 2(degree+1). Cubic (degree 3) with all-1 weights gives smooth trumpet profiles for revolutions.
- `Material.Create(doc, name)` returns **ElementId** (not Material) — then `doc.GetElement(id)` to set `.Color`.
- Assign material to family solids: `solid.get_Parameter(DB.BuiltInParameter.MATERIAL_ID_PARAM).Set(matId)`.
- Extrusion/revolution solids in a family are `DB.GenericForm` (collector for verification).
- Family lifecycle: `app.NewFamilyDocument(templatePath)` → build inside own Transaction → `fam.SaveAs(path, SaveAsOptions{OverwriteExistingFile=true})` → `fam.Close(False)`. Template: `C:\ProgramData\Autodesk\RVT 2027\Family Templates\English\Metric Furniture.rft` (category Furniture included).
- Units: everything internal is **feet** — `MM = 1.0/304.8` multiplier everywhere.
- Verify by reopening: `app.OpenDocumentFile(path)`, read `get_BoundingBox(None)` per GenericForm, convert ×304.8, then `Close(False)`.

**Probe-first workflow that works:** when an API name fails, write a tiny probe script using `clr.GetClrType(DB.SomeType).GetMethods(BindingFlags.Public|Static|DeclaredOnly)` and print overload signatures (`p.ParameterType.Name + ' ' + p.Name`). NOTE: reflection needs `clr.GetClrType()` — the raw IronPython type object has no `.GetMethods`.

## 3. pyRevit 6.x forms API renames

- `forms.select_folder()` → **`forms.pick_folder(title=...)`** (uses CommonOpenFileDialog, returns path or None)
- `forms.select_file()` → **`forms.pick_file()`**
- Unchanged: `forms.alert`, `forms.ProgressBar(title=, cancellable=True)` with `pb.update_progress(v, max)` / `pb.cancelled`, `revit.Transaction('name', doc=...)` context manager.
- Old names survive only in the legacy `rpw.ui.forms` wrapper — don't use.
- Symptom of a renamed call: script dies AFTER all imports with AttributeError; the pyRevit runtime log just stops at `pyrevit.forms._ipy:exit`.

## 4. pyRevit install/repair on Revit 2027 (.NET 10)

- Revit 2025/2026 = .NET 8; **Revit 2027 = .NET 10**. pyRevit ≥6.4 supports it (PR #3040); engine ships `pyRevitLabs.PyRevit.Runtime.2027.dll`.
- **`System.IO.FileSystem.DriveInfo, Version=10.0.0.0` FileNotFoundException at startup** (IronPython double-fault hiding the real error): `pyrevitlib/pyrevit/framework.py` does `clr.AddReference('System.IO.FileSystem.DriveInfo')` which fails in the loader's ALC. **Fix: copy the DLL from `C:\Program Files\dotnet\shared\Microsoft.NETCore.App\<ver>\` into both `…\pyRevit-Master\bin\netcore\` and `…\bin\netcore\engines\IPY2712PR\`.** Verified working.
- Diagnose startup failures via the **Revit journal** (`%LOCALAPPDATA%\Autodesk\Revit\Autodesk Revit 2027\Journals\journal.*.txt`): search `PyRevit` / `API_ERROR` — the "Assembly version conflict" block names the real mismatched references.
- Enable pyRevit debug logging: CLI has no `config logging` command in 6.x — edit `%APPDATA%\pyRevit\pyRevit_config.ini`: `[core]` section with `filelogging = true`, `verbose = true`, `debug = true`. Logs land in `%APPDATA%\pyRevit\<year>\pyRevit_<year>_<pid>_runtime.log`.
- CLI essentials: `pyrevit env`, `pyrevit attached`, `pyrevit attach master default --installed`, `pyrevit caches clear --all`, `pyrevit extensions paths add <folder>`.
- Silent install: `pyRevit_<ver>_signed.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART` (Inno Setup).

## 5. Extension authoring (custom tabs/buttons)

Folder grammar: `MyTools.extension\MyTools.tab\MyPanel.panel\My Command.pushbutton\script.py` (+ optional `bundle.yaml` with `title:`/`tooltip:`, `icon.png`). Register parent folder once: `pyrevit extensions paths add C:\path\to\parent`. pyRevit auto-detects script changes on click; use pyRevit tab → Reload for structural changes. IronPython 2.7.12 is the default engine — write PY2/PY3-compatible code (`.format()`, no f-strings). Full-folder family loader and other working examples live in `D:\OneDrive\OneDrive\Projects\HOUSE\Corbielaan 17\scriptes\`.

## 6. Modal dialogs block EVERYTHING

Any open pyRevit/Revit dialog (e.g. a `forms.alert` left open) freezes the revit_* MCP connection and can stall `pyrevit run` journal replay. Before scripted runs: check `Get-Process Revit` MainWindowTitle for dialog titles and have the user close them.

## 7. Parametric-by-visibility: the reliable way to make variant-rich families

Verified on a 7-family / 544-type IKEA cabinet generator. Fully parametric geometry (constraints/locks/labels) is fragile and slow to iterate via journal replay. Instead:

1. Bake every variant as solids inside the family.
2. Associate each solid's `Visible` element param to a Yes/No **family** parameter (one per variant).
3. Types toggle visibility params + material params. Types are cheap; hundreds per family work fine.

**Verified FamilyManager API facts (2027):**
- `fm.AddParameter(name, GroupTypeId.General, SpecTypeId.Boolean.YesNo, False)` — works. **`GroupTypeId.Dimensions` does NOT exist**; use `General` for Length params (`SpecTypeId.Length`), `GroupTypeId.Materials` + `SpecTypeId.Reference.Material` for material params.
- `fm.AssociateElementParameterToFamilyParameter(elemParam, familyParam)` — works for both the element `Visible` param (find by `Definition.Name == 'Visible'`) and `MATERIAL_ID_PARAM`.
- **Yes/No family params default to TRUE (1) on newly created types** — after the first `NewType`, explicitly Set all to 0 before setting the active one, or every variant shows at once.
- `fm.NewType(name)` duplicates the CURRENT type and makes the new one current; `fm.Set()` then applies to it. Pattern: `Set(prevVis, 0); Set(ownVis, 1)` per type.
- `fm.Set(fp, elementId)` sets material params per type.
- **Material params as INSTANCE params** (`AddParameter(..., True)`) associate fine and let users override color per placed instance — often preferable to baking color types.
- **New materials show GRAY in shaded views unless you set `mat.UseRenderAppearanceForShading = False`** — `mat.Color` alone is not enough (learned the hard way: user reported "colors not filled in" on 544 color-variant types).
- **`fm.CurrentType = t` (and `Regenerate`) requires an open Transaction**, even for read-verify scenarios.
- **ElementId values repeat across family documents** — NEVER cache Parameter objects keyed by `ElementId.Value` across docs; you get "This parameter cannot be associated" from stale cross-doc references (cost 3 family builds to find).
- After `CurrentType` set + `Regenerate`, an element's `Visible` param `AsInteger()` reads the computed per-type value — usable for verification.
- `FamilyType.AsInteger(fp)` / `.AsElementId(fp)` read per-type values without changing CurrentType.
- Batch: build all families in ONE script with per-family transactions + resume logic (skip existing .rfa) — stalls/timeouts then cost nothing.
- **Reloading a family into a project NEVER prunes types** — types absent from the new .rfa persist in the project and accumulate across reloads (observed: 264 old + 33 new = 297 types after user reloaded). To change type structure, delete the family (if no instances) or delete unused FamilySymbols first, then LoadFamily. `pyrevit run script.py model.rvt --revit=2027` runs against a model file headlessly (must be closed in the UI; abort if `doc.IsWorkshared`).

- **ALL document modifications must be inside the Transaction, including `OwnerFamily.FamilyCategory = ...`** — setting it before `tx.Start()` throws "Attempt to modify the model outside of transaction" (or the cryptic "A sub-transaction can only be active inside an open Transaction" later at AddParameter). Hit this twice (Bosch + bedroom generators).
- Category enum spellings (2027): `OST_SpecialityEquipment` (British "Speciality" — `OST_SpecialtyEquipment` does NOT exist), `OST_Casework`, `OST_Furniture`, `OST_PlumbingFixtures`.
- Template paths: `Metric Furniture.rft`, `Metric Plumbing Fixture.rft`, `Metric Specialty Equipment.rft` under `C:\ProgramData\Autodesk\RVT 2027\Family Templates\English\`.

## 10. Schedulable parameters & schedules (verified 2027)

- **Regular (non-shared) family parameters are NOT schedulable in projects** — they never appear in `GetSchedulableFields()`. For schedule-visible family data you MUST use **shared parameters**: create a .txt shared-parameter file (`app.SharedParametersFilename = path` + `app.OpenSharedParameterFile()`), `Groups.Create/get_Item` → `Definitions.Create(ExternalDefinitionCreationOptions(name, SpecTypeId.Volume))`, then in each family `fm.AddParameter(extDef, DB.GroupTypeId.General, False)` and `fm.Set` per type. Replace an existing non-shared param of the same name first (`fm.RemoveParameter`) or AddParameter conflicts.
- **Shared-definition handles go STALE across documents** — reusing one `ExternalDefinition` in a 5th consecutive family doc threw `SEHException` in `FamilyParamsUtil.addExternalParameter`. Re-open the DefinitionFile and re-fetch the definition per document.
- Schedule recipe that works: `ViewSchedule.CreateSchedule(doc, categoryId)` → `defn.AddField` by matching `sf.GetName(doc)` ('Family', 'Type', 'Count', '<shared param>') → `field.DisplayType = ScheduleFieldDisplayType.Totals` → `defn.ShowGrandTotal = True`, `AddSortGroupField`, `AddFilter(ScheduleFilter(fieldId, ScheduleFilterType.Contains, 'IKEA_'))`, `SetFieldOrder` → `doc.Regenerate()` → read back via `sched.GetTableData().GetSectionData(SectionType.Body)` + `sched.GetCellText(...)`. Filter target field must itself be an added field ('Family' works, 'Family Name' does not exist).
- **OneDrive gotcha**: users reorganize folders between sessions (renamed dirs, moved .rfa files) — never trust paths from an earlier session; search/verify before scripted runs ("file ... to be opened doesn't exist" while Test-Path in another shell disagrees).
- Volume params display in project units (m³); compute in cm³ and convert to ft³ (÷28316.85) when Setting values.

## 9. Materials & appearance assets (verified 2027)

- **`ElementTransformUtils.CopyElements` project↔family is BLOCKED** ("Copying one or more elements failed" + modal error dialog in the spawned instance — the dialog then stalls the run until killed). Copy project↔project only.
- **Asset properties are read-only outside `AppearanceAssetEditScope`** — `IsEditable()` returns False for every prop and setters throw "Asset can be edited only in an edit scope", even on duplicated assets.
- **AppearanceAssetEditScope WORKS in pyrevit-run context** (no hang, unlike the MCP-executor context): `aae.Duplicate(name)` → `scope = DB.Visual.AppearanceAssetEditScope(doc)` → `editable = scope.Start(ae.Id)` → type-aware edits → `scope.Commit(True)` + `scope.Dispose()`.
- Type-aware editing is required: only call `SetValueAsColor` on `AssetPropertyDoubleArray*` (skip `*_colorspace`), `SetValueAsDouble` on `AssetPropertyDouble`. **`AssetPropertyBoolean` has NO working setter in IronPython** (neither SetValueAsBoolean nor SetValueAsInteger) — tint toggles can't be enabled; set the schema's base color prop directly instead (`wallpaint_color`, `hardwood_tint_color`, `<schema>_color`).
- **Material names ≠ appearance asset names** (e.g. "Yellow Pine - Solid Stained Dark Medium Gloss" is an AE name, not a material). Search both collectors.
- Cheapest route to rich project materials: `familyLoadedMat.AppearanceAssetId = existingProjectMat.AppearanceAssetId` (e.g. assign the project's real "Walnut"/"Iron, Ductile" assets to family-loaded material copies). No edit scope needed for assignment.
- Set `mat.Color` + `UseRenderAppearanceForShading = False` for exact shaded-view colors; set True when the assigned appearance already has the right color.
- Family-template (Metric Furniture) appearance assets are all size-0/noneditable — you cannot create rich appearances inside a fresh family doc; do rich material work in the project instead.

## 8. Stall diagnosis deep-dive

Empty "Execution Log" + zero-byte `PyRevitRunner_*.log` = spawned instance died before executing. Check `%TEMP%\<guid>\journal.0001.txt` tail: repeated "Finish downloading Revit config from service" = spawned instance stuck on Autodesk cloud config sync (environmental, transient — wait 30s and retry). Health-check the runner with a 1-line `print('PING OK')` script to isolate environment vs script problems.
