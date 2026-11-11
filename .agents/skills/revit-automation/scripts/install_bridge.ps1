<#
.SYNOPSIS
  Installs the Revit Agent Bridge (pyRevit extension + Routes server).

.DESCRIPTION
  1. Junctions bridge\AgentBridge.extension into a pyRevit extension search path
     (default: $env:USERPROFILE\pyRevit, registered with pyRevit if needed).
  2. Enables the pyRevit Routes server (`pyrevit configs routes enable`).
  3. Prints next steps. Revit must be (re)started afterwards.

  Idempotent. Uninstall: -Uninstall (removes junction, disables routes).
#>
param(
    [string]$ExtensionsDir = (Join-Path $env:USERPROFILE 'pyRevit'),
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$src  = Join-Path $PSScriptRoot '..\bridge\AgentBridge.extension' | Resolve-Path
$link = Join-Path $ExtensionsDir 'AgentBridge.extension'

if (-not (Get-Command pyrevit -ErrorAction SilentlyContinue)) {
    throw 'pyrevit CLI not found on PATH. Install pyRevit first (https://github.com/pyrevitlabs/pyRevit/releases).'
}

if ($Uninstall) {
    if (Test-Path $link) { (Get-Item $link).Delete(); Write-Host "Removed $link" }
    pyrevit configs routes disable
    Write-Host 'Routes disabled. Restart Revit.'
    return
}

New-Item -ItemType Directory -Force $ExtensionsDir | Out-Null
if (Test-Path $link) { (Get-Item $link).Delete() }
New-Item -ItemType Junction -Path $link -Target $src | Out-Null
Write-Host "Linked $link -> $src"

$paths = (pyrevit extensions paths) -join "`n"
if ($paths -notmatch [regex]::Escape($ExtensionsDir)) {
    pyrevit extensions paths add $ExtensionsDir
    Write-Host "Registered extension path $ExtensionsDir"
}

pyrevit configs routes enable
pyrevit configs routes
Write-Host ''
Write-Host 'Done. (Re)start Revit, then verify with:'
Write-Host "  python `"$PSScriptRoot\revit_bridge.py`" ping"
