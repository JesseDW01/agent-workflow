---
name: sketchup
description: Use whenever the user wants to create, inspect, modify, or export geometry in SketchUp Pro, or asks anything about the live SketchUp model. Covers the sketchup MCP tools (sketchup-mcp2 bridge), connection startup, SketchUp Ruby API usage via eval_ruby, units conventions, and troubleshooting.
---

# SketchUp Pro Integration

SketchUp Pro 2026 is controlled through the **sketchup** MCP server (sketchup-mcp2 v0.3.0): a Python MCP bridge (`uvx sketchup-mcp2`) talking over TCP `127.0.0.1:9876` to a Ruby extension inside SketchUp. Registered in `~/.config/opencode/opencode.json`.

## Pre-flight checklist (do this BEFORE any modeling work)

1. **SketchUp must be running** with a model open.
2. **The extension server must be started**: in SketchUp → `Plugins → MCP Server → Start Server`. This is a manual step the user must do once per SketchUp session — if tool calls fail with "SketchUp not running or extension not started", ask the user to do this.
3. Verify connectivity with `get_version` before any mutating call.

## Tool catalogue

| Category | Tools |
|---|---|
| Geometry | `create_component` (cube/cylinder/cone/sphere), `delete_component`, `transform_component` |
| Materials | `set_material` (named colors or `#rrggbb`) |
| Booleans | `boolean_operation` (union/difference/intersection) |
| Edge ops | `chamfer_edge`, `fillet_edge` |
| Joinery | `create_mortise_tenon`, `create_dovetail`, `create_finger_joint` |
| Export | `export_scene` (skp/obj/dae/stl/png/jpg) |
| Introspection | `get_model_info`, `list_components` (paginated: limit/offset), `get_component_info`, `find_components`, `list_layers`, `create_layer`, `get_selection`, `get_version` |
| View | `get_viewport_screenshot` (PNG image; optional view_preset/style/zoom_extents; needs SU 2026+) |
| Lifecycle | `undo` (single call = one undo step) |
| Escape hatch | `eval_ruby` — arbitrary Ruby in SketchUp (enabled by default in this install) |

## Conventions (critical)

- **All dimensions in millimeters; angles in degrees.** SketchUp's Ruby API natively uses inches — the MCP tools convert for you, but in `eval_ruby` you must convert (`x.mm`, `x.degrees` are your friends).
- `transform_component` `position` is an **absolute** target: it sets the component's bbox-min corner in world space (mm). Idempotent, NOT a relative offset.
- Entity-returning tools respond with `bbox_mm`. **Re-locate entities by bounding box** if IDs go stale after destructive operations (booleans, deletes).
- Every mutation is wrapped in one undoable operation — `undo` rolls back a whole tool call.
- After mutations, verify with `bbox_mm` / `get_model_info` / `get_viewport_screenshot` before proceeding.

## Typed tools vs eval_ruby

- Prefer **typed tools** for anything they cover — validated, undoable, safer.
- Use `eval_ruby` for everything else: groups, faces/edges from raw points, `follow_me` extrusions, scenes/cameras, imports, attribute dictionaries, selection manipulation, batches of geometry.
- In `eval_ruby`, ALWAYS wrap mutations yourself:
  ```ruby
  model = Sketchup.active_model
  model.start_operation('My op', true)
  # ... work ...
  model.commit_operation
  ```
- Keep `eval_ruby` bodies small. A runaway loop freezes SketchUp's UI (everything runs on the UI thread). Break big jobs into multiple calls.
- Return values matter: make the last expression a compact summary (Hash/Array) — that's what you get back.

**For non-trivial Ruby work (framed walls, roofs, joist arrays, follow_me, world-space transforms, boolean pitfalls like reversed `Group#subtract`), read `ruby-cookbook.md` in this skill's directory first** — it contains tested recipes and known traps.

## Modeling strategy

1. Understand the ask; check `get_model_info` / `get_selection` for context.
2. Plan geometry in mm; create components bottom-up; name things (`name` param on `create_component`).
3. Apply materials after geometry exists.
4. Verify: screenshot + bbox checks. Fix before reporting done.
5. Offer export if the user wants fabrication/print output.

## Troubleshooting

- **"SketchUp not running or extension not started"** → ask user to open SketchUp and `Plugins → MCP Server → Start Server`. The Python side retries on the next call — just retry after they confirm.
- **`IncompatibleVersionError`** → Python package and .rbz out of sync. Fix: `uvx --from sketchup-mcp2@latest ...` refresh and/or reinstall the latest `mcp_for_sketchup_v*-github-signed.rbz` from https://github.com/zinin/sketchup-mcp2/releases into `%AppData%\SketchUp\SketchUp 2026\SketchUp\Plugins`.
- **Tool-call timeout** → operation too big; split it, or raise `SKETCHUP_MCP_TIMEOUT` in opencode.json (currently 60s).
- **Ruby errors** → check SketchUp's Ruby Console (`Window → Ruby Console`); extension logs are prefixed `[MCPforSU]`.
- Never bind host to `0.0.0.0` — `eval_ruby` = unauthenticated arbitrary code execution on the LAN.

## Reference

- Project: https://github.com/zinin/sketchup-mcp2 (v0.3.0, github-signed variant, eval_ruby on)
- SketchUp Ruby API docs: https://ruby.sketchup.com/
- Local cookbook: `ruby-cookbook.md` (same directory as this file)
