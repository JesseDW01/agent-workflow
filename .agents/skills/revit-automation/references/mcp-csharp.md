# Channel B — revit_* MCP (C# executor)

> Ported from the opencode `revit-api-automation` skill (Revit 2027, verified). In Claude Code the tools are named `mcp__revit__<tool>` (e.g. `mcp__revit__send_code_to_revit`) once the MCP is registered (see SKILL.md → Setup). The API facts here also apply to the live bridge and headless channels.

Learnings from real Revit 2027 sessions through the `revit_*` MCP tools. Verified empirically — trust this over generic Revit API knowledge where they conflict.

## 1. `revit_send_code_to_revit` Executor Contract

Your code is injected into a **static** method with this signature:

```csharp
static object Execute(Document document, object[] parameters)
```

- **Document variable is `document`** — NOT `doc`, NOT `this.Document`, NOT `commandData`.
- **`this` is invalid** (static context). Don't reference it.
- **Return a string** to get output back in the tool result JSON. Fallback: also `File.WriteAllText` to a temp path and read it locally.
- **NEVER open your own `Transaction`** — the executor wraps execution in one. Starting one throws *"Starting a new transaction is not permitted"*. Just call document-modifying APIs directly (Create, Set, Delete all work bare).
- **Compile errors** come back in `errorMessage` with line numbers; the run is aborted entirely. Iterate fast.
- If unsure of the contract, probe it:

```csharp
var m = System.Reflection.MethodBase.GetCurrentMethod();
foreach (var p in m.GetParameters()) /* p.Name, p.ParameterType.FullName */
```

## 2. Probe the Runtime API Instead of Assuming

The compile-time API surface may not match your training knowledge. When a known method/enum fails to compile, enumerate the truth via reflection:

```csharp
Enum.GetNames(typeof(ScheduleFieldType))                       // enum values
typeof(ScheduleField).GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
asm.GetTypes().Where(t => t.Name.Contains("Formula"))          // find candidate types
```

Runtime reflection is definitive — the executing assembly is the real Revit version.

## 3. Verified Revit 2027 API Facts

- `ElementId.Value` (long). `IntegerValue` does NOT exist. Construct from long: `new ElementId((long)id)`.
- `element.GetMaterialArea(matId, false)` — 2 args required. `element.GetMaterialVolume(matId)` — 1 arg ONLY (no bool overload).
- Material cost parameter: `material.get_Parameter(BuiltInParameter.ALL_MODEL_COST)` — Double storage, Currency spec (`autodesk.spec.measurable:currency-2.0.0`).
- Element phase: `element.get_Parameter(BuiltInParameter.PHASE_CREATED).AsValueString()` returns the phase name string.
- Elements with material quantities: `WhereElementIsNotElementType()` + `e.Category != null && e.Category.HasMaterialQuantities`.
- Areas/volumes are internal units (sq ft / cu ft): `UnitUtils.ConvertFromInternalUnits(v, UnitTypeId.SquareMeters)`.
- **Creation return types are inconsistent** (cost 3 compile iterations): `Material.Duplicate(name)` → `Material`, but `Material.Create(doc, name)` → `ElementId`. Don't guess — when a conversion error appears, flip the handling.
- Fill pattern creation: `new FillPattern(name, FillPatternTarget.Model, FillPatternHostOrientation.ToHost, angleRadians, spacing1, spacing2)` (spacings in feet) + `FillPatternElement.Create(doc, fillPattern)`. Enum is `FillPatternHostOrientation`, NOT `FillPatternOrientation`.
- Assign patterns: `material.SurfaceForegroundPatternId = fillPatternElement.Id`; shading color via `material.Color` + `material.UseRenderAppearanceForShading = false`.
- **AppearanceAssetEditScope / `Application.get_Assets(AssetType.Appearance)` can hang Revit and pop modal dialogs** — the whole executor call then times out and its transaction rolls back (nothing persists). Avoid, or isolate in its own call AFTER base creation is committed. Prefer duplicating an existing material to inherit its appearance asset instead.
- **Appearance asset editing (verified working recipe):**
  - Asset types live in `Autodesk.Revit.DB.Visual` (Asset, AssetProperty, AssetPropertyDoubleArray4d, AppearanceAssetEditScope) — the executor template does NOT import this namespace; **fully qualify** or you get "inaccessible/not found" compile errors.
  - `Material.Duplicate` **SHARES** the appearance asset with the source (editing one affects both). Get an independent asset via `AppearanceAssetElement.Duplicate(name)` (returns AppearanceAssetElement, cheap, no dialog) then assign `mat.AppearanceAssetId`.
  - `Asset` is NOT IEnumerable — enumerate via `asset.Size` + `asset[i]` indexer. Check `AssetProperty.IsEditable()` before writing.
  - Tint: set `<schema>_color` (e.g. `concrete_color`) AND `common_Tint_color` via `SetValueAsColor(Color)`; enable `common_Tint_toggle` if you want the tint multiplier active. Keep connected bump/texture maps for realism.

## 4. Material Takeoff Schedule Recipe (verified working)

```csharp
var sched = ViewSchedule.CreateMaterialTakeoff(doc, ElementId.InvalidElementId); // multi-category
var def = sched.Definition;
foreach (var f in def.GetSchedulableFields()) {
    var n = f.GetName(doc);
    if (n == "Material: Name") fName = def.AddField(f);   // keep ScheduleField refs
    // "Material: Cost", "Material: Area", "Material: Volume" also exist
}
def.IsItemized = false;                                  // one row per material
def.AddSortGroupField(new ScheduleSortGroupField(fName.FieldId, ScheduleSortOrder.Ascending));
def.ShowGrandTotal = true;
fArea.DisplayType = ScheduleFieldDisplayType.Totals;     // else grouped rows show "<varies>"
def.SetFieldOrder(new List<ScheduleFieldId> { fName.FieldId, fCost.FieldId, fArea.FieldId });
doc.Regenerate();                                        // required before reading table data
```

**Read back / verify:**

```csharp
var body = sched.GetTableData().GetSectionData(SectionType.Body);
sched.GetCellText(SectionType.Body, row, col);
```

## 5. Phase Filtering a Schedule — IT WORKS (verified)

Common belief: "material takeoffs can't be filtered by phase." TRUE for the Filter tab (`GetSchedulableFields()` has no Phase field). **BUT the schedule VIEW honors view phase settings** — set both:

```csharp
sched.get_Parameter(BuiltInParameter.VIEW_PHASE).Set(ncPhaseId);          // Phase element id
sched.get_Parameter(BuiltInParameter.VIEW_PHASE_FILTER).Set(showNewId);   // PhaseFilter "Show New" id
doc.Regenerate();  // rows AND aggregate areas recompute to phase-only
```

Verified: 33 → 15 rows; overlapping materials showed phase-only areas matching independent computation. Find phases/filters via `FilteredElementCollector(doc).OfClass(typeof(Phase))` / `typeof(PhaseFilter)`.

## 6. Confirmed API Limitations (don't waste time)

- **Calculated-value (formula) schedule columns CANNOT be created via API** (still true in 2027):
  - `AddField(ScheduleFieldType.Formula)` and `InsertField` → *"fieldType is not a schedulable field type"* (regular schedules too).
  - `TableCellCalculatedValueData` has no public constructor/factory; only `TableSectionData.Get/SetCellCalculatedValue` (get-only in practice).
  - `ScheduleField` has no `SetFormula`. `FormulaManager` only validates/evaluates formula strings.
  - **Workaround:** user adds it manually — schedule Properties → Fields → Calculated Value → Type Currency → formula `Material: Cost * Material: Area` (fallback `/ 1 m²` if "Inconsistent units").
- `ScheduleFieldType.CustomField` needs a custom-field server id constructor — not usable directly.

## 7. Connectivity / Tool Failures

- `connect to revit client failed` → Revit not running or MCP add-in not loaded.
- `operation timed out` → Revit busy or a **modal dialog is open**; ask user to close dialogs and click into Revit.
- Retry after user confirms; the connection usually recovers without restart.

## 8. Working Style That Succeeded

1. Probe first (contract → runtime API → project data) before building.
2. Build in one `send_code` call; verify in a second call by reading back actual schedule cells.
3. Compare schedule numbers against independently computed quantities (e.g., per-phase `GetMaterialArea` sums) before declaring success.
4. Surface hard limitations with evidence and a manual workaround rather than faking a solution.
