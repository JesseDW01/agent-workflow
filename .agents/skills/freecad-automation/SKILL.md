---
name: freecad-automation
description: "Drive FreeCAD programmatically on Windows via the FreeCAD Python API and the Robust MCP Bridge. Covers portable install, PYTHONPATH/PATH setup, headless bridge startup, verified API patterns, units, and common pitfalls. USE FOR: freecad, freecad mcp, create freecad model, script freecad, freecad python api, robust mcp bridge, freecad headless. DO NOT USE FOR: Revit, pyRevit, general CAD concepts without FreeCAD."
metadata:
  author: Sisyphus
  version: "1.0.0"
---

# FreeCAD Automation on Windows

Learnings from installing FreeCAD 1.1.3 and the Robust MCP Bridge on Windows and driving it headlessly. Verified empirically.

## 1. Installation Layout

Use the **portable .7z release** from GitHub to avoid admin rights issues:

```
https://github.com/FreeCAD/FreeCAD/releases
Asset: FreeCAD_1.1.3-Windows-x86_64-py311.7z
```

Extract with Windows `tar` (bsdtar handles 7z):

```powershell
tar -xf FreeCAD_1.1.3-Windows-x86_64-py311.7z -C C:\Users\<you>\FreeCAD
```

Resulting tree:

```
C:\Users\<you>\FreeCAD\FreeCAD_1.1.3-Windows-x86_64-py311
├── bin\              # FreeCAD.pyd, FreeCADGui.pyd, FreeCADCmd.exe, DLLs
├── lib\              # additional Python modules and .pyd files
├── Mod\              # built-in workbenches
├── FreeCAD.exe
└── FreeCADCmd.exe
```

**Critical:** `FreeCAD.pyd` lives in `bin\`, not `lib\`.

## 2. Environment Variables

Set these in **user** scope:

```powershell
$fcRoot = "C:\Users\<you>\FreeCAD\FreeCAD_1.1.3-Windows-x86_64-py311"
[Environment]::SetEnvironmentVariable('FREECAD_PATH', $fcRoot, 'User')
[Environment]::SetEnvironmentVariable('FREECAD_MODE', 'xmlrpc', 'User')

# PATH: prepend FreeCAD bin + Python user Scripts
$path = [Environment]::GetEnvironmentVariable('PATH', 'User')
$scripts = "C:\Users\<you>\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.11_qbz5n2kfra8p0\LocalCache\local-packages\Python311\Scripts"
[Environment]::SetEnvironmentVariable('PATH', "$fcRoot\bin;$scripts;$path", 'User')

# PYTHONPATH: prepend FreeCAD bin + lib
$pp = [Environment]::GetEnvironmentVariable('PYTHONPATH', 'User')
[Environment]::SetEnvironmentVariable('PYTHONPATH', "$fcRoot\bin;$fcRoot\lib;$pp", 'User')
```

A **new shell/session** is required to pick up the changes.

## 3. Quick Sanity Check

```powershell
python -c "import FreeCAD as App; print(App.Version())"
```

Expected output similar to:

```
['1', '1', '3', '20260725 (Git shallow)', ...]
```

## 4. Robust MCP Bridge Setup

The bridge runs **inside** FreeCAD and exposes XML-RPC (port 9875) and JSON-RPC socket (port 9876).

### 4.1 Install the bridge workbench

Clone/copy the workbench into FreeCAD's user Mod directory:

```powershell
$mod = "$env:APPDATA\FreeCAD\Mod"
git clone --depth 1 https://github.com/spkane/freecad-addon-robust-mcp-server.git
Copy-Item -Recurse freecad-addon-robust-mcp-server\freecad\RobustMCPBridge $mod\
```

### 4.2 Install the MCP server package

```powershell
pip install freecad-robust-mcp mcp==1.29.0
```

**Important:** `mcp` 2.0.0 removed `mcp.server.fastmcp`; pin to the latest 1.x (verified: 1.29.0).

### 4.3 Headless bridge startup script

Save as `start_mcp_bridge.py`:

```python
r"""Start the Robust MCP Bridge inside FreeCAD and keep running."""
import sys
import time
import traceback

sys.path.insert(0, r"C:\Users\<you>\AppData\Roaming\FreeCAD\Mod\RobustMCPBridge")

import FreeCAD as App

print("FreeCAD loaded:", ".".join(App.Version()[:3]))

try:
    from freecad_mcp_bridge.server import FreecadMCPPlugin
    plugin = FreecadMCPPlugin(
        host="localhost",
        port=9876,
        xmlrpc_port=9875,
        enable_xmlrpc=True,
    )
    plugin.start()
    print("MCP Bridge started:")
    print("  - XML-RPC: localhost:9875")
    print("  - Socket:  localhost:9876")
except Exception as e:
    print("Failed to start MCP Bridge:", e)
    traceback.print_exc()
    raise

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    print("Shutting down...")
```

Run it:

```powershell
FreeCADCmd.exe C:\Users\<you>\FreeCAD\start_mcp_bridge.py
```

Or wrap in a batch file:

```bat
@echo off
set FC_ROOT=C:\Users\<you>\FreeCAD\FreeCAD_1.1.3-Windows-x86_64-py311
"%FC_ROOT%\bin\FreeCADCmd.exe" C:\Users\<you>\FreeCAD\start_mcp_bridge.py
```

### 4.4 Verify the MCP server can connect

With the bridge running:

```powershell
$env:FREECAD_MODE = 'xmlrpc'
freecad-mcp --check
```

Expected: `✓ Connection successful!` + FreeCAD version.

### 4.5 GUI auto-start (optional)

To make the bridge start automatically when FreeCAD GUI launches, set the workbench preference from FreeCAD's Python:

```python
import FreeCAD as App
param = App.ParamGet('User parameter:BaseApp/Preferences/Mod/RobustMCPBridge')
param.SetBool('AutoStart', True)
param.SetInt('XMLRPCPort', 9875)
param.SetInt('SocketPort', 9876)
```

Run with `FreeCADCmd.exe set_pref.py`.

## 5. Verified FreeCAD Python API Facts

- **Documents:** `App.newDocument('Name')`, `App.closeDocument('Name')`, `doc.recompute()`.
- **Primitives:** `doc.addObject('Part::Box', 'Box')`; set `Length`, `Width`, `Height`; call `doc.recompute()` before reading `Shape.Volume`.
- **Length units:** `Length`, `Width`, `Height`, etc. are in **millimetres** for Part primitives by default.
- **Workbench activation:** `Gui.activateWorkbench('PartDesignWorkbench')` (only in GUI mode).
- **Headless limitations:** No GUI workbench activation, no screenshots, no view/camera tools. Core Part/PartDesign geometry creation works fine.
- **Import pattern:**

```python
import FreeCAD as App
import Part
import Sketcher
import PartDesign
```

## 6. Common Pitfalls

- `No module named 'FreeCAD'` → `PYTHONPATH` is missing the `bin` directory or a new shell hasn't been opened.
- `charmap` / UnicodeEncodeError from `freecad-mcp --check` → set console to UTF-8: `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` and `$env:PYTHONIOENCODING = 'utf-8'`.
- `ModuleNotFoundError: No module named 'mcp.server.fastmcp'` → installed `mcp` 2.x; downgrade to `mcp==1.29.0`.
- Bridge not listening → check that `FreeCADCmd.exe` is actually running and that ports 9875/9876 are not blocked or already in use.
- `embedded` mode on Windows/macOS → **do not use**. It crashes on Windows. Always use `xmlrpc` or `socket` mode.

## 7. Typical Agent Workflow

1. Ensure the bridge is running (`start_mcp_bridge.bat`).
2. From a new shell, set `$env:FREECAD_MODE = 'xmlrpc'`.
3. Run `freecad-mcp` (stdio transport) or call FreeCAD directly from Python.
4. For pure scripting without MCP, set env vars and use `python script.py` with `import FreeCAD`.
