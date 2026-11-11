#!/usr/bin/env python3
"""Client for the Revit Agent Bridge (pyRevit Routes, live session).

Stdlib only. Usage:

  python revit_bridge.py ping
  python revit_bridge.py exec script.py [--tx "Name"] [--rollback] [--fresh] [--args '{"k":1}']
  python revit_bridge.py exec -c "result = doc.Title"
  python revit_bridge.py snapshot out.png [--view "Level 1"] [--px 1600]
  python revit_bridge.py port            # just print the discovered port

Env:
  REVIT_BRIDGE_PORT   force a port (otherwise scans 48884..48893)
  REVIT_BRIDGE_TOKEN  override the token (otherwise read from
                      %APPDATA%\\pyRevit\\agent_bridge_token.txt)

Exit code 0 on ok, 1 on Revit-side error, 2 on connection problems.
Output is JSON on stdout (stdout of the Revit code is in "stdout").
"""
import argparse
import glob
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request

HOST = "127.0.0.1"
BASE_PORT = 48884
SCAN = 10


def token():
    tok = os.environ.get("REVIT_BRIDGE_TOKEN")
    if tok:
        return tok.strip()
    path = os.path.join(os.environ.get("APPDATA", ""), "pyRevit", "agent_bridge_token.txt")
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        print(json.dumps({"ok": False, "error": "Token file not found: %s. "
                          "Is the AgentBridge extension installed and Revit started "
                          "since? (scripts/install_bridge.ps1)" % path}))
        sys.exit(2)


def post(port, route, body, timeout):
    body = dict(body, token=token())
    req = urllib.request.Request(
        "http://%s:%d/agent/%s" % (HOST, port, route),
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return json.loads(raw)
        except ValueError:
            return {"ok": False, "error": "HTTP %d" % e.code, "body": raw}


def discover(timeout=5):
    env = os.environ.get("REVIT_BRIDGE_PORT")
    ports = [int(env)] if env else range(BASE_PORT, BASE_PORT + SCAN)
    errors = []
    for p in ports:
        try:
            res = post(p, "ping", {}, timeout)
            if res.get("ok"):
                return p, res
            errors.append("%d: %s" % (p, res.get("error")))
        except Exception as e:  # connection refused / timeout
            errors.append("%d: %s" % (p, e.__class__.__name__))
    print(json.dumps({
        "ok": False,
        "error": "No Agent Bridge reachable. Is Revit open, idle (no modal dialog / edit mode), "
                 "routes enabled ('pyrevit configs routes enable') and Revit restarted?",
        "tried": errors,
    }, indent=2))
    sys.exit(2)


def run_exec(port, code, a):
    body = {"code": code, "fresh": a.fresh, "rollback": a.rollback}
    if a.tx:
        body["transaction"] = a.tx
    if a.args:
        body["args"] = json.loads(a.args)
    try:
        return post(port, "exec", body, a.timeout)
    except Exception as e:
        print(json.dumps({
            "ok": False,
            "error": "%s: %s" % (e.__class__.__name__, e),
            "hint": "TIMEOUT DOES NOT CANCEL: the ExternalEvent stays queued and will run "
                    "when Revit becomes idle. Check model state before re-sending "
                    "modifying code. Ask the user to close dialogs / press Esc.",
        }, indent=2))
        sys.exit(2)


SNAPSHOT_CODE = r'''
import os
v = doc.ActiveView
if args.get("view"):
    cands = [x for x in DB.FilteredElementCollector(doc).OfClass(DB.View)
             if not x.IsTemplate and x.Name == args["view"]]
    if not cands:
        raise Exception("View not found: %s" % args["view"])
    v = cands[0]
o = DB.ImageExportOptions()
o.ExportRange = DB.ExportRange.SetOfViews
from System.Collections.Generic import List
o.SetViewsAndSheets(List[DB.ElementId]([v.Id]))
o.FilePath = os.path.join(args["dir"], "snap")
o.ZoomType = DB.ZoomFitType.FitToPage
o.PixelSize = int(args["px"])
o.FitDirection = DB.FitDirectionType.Horizontal
o.HLRandWFViewsFileType = DB.ImageFileType.PNG
o.ShadowViewsFileType = DB.ImageFileType.PNG
o.ImageResolution = DB.ImageResolution.DPI_150
doc.ExportImage(o)
result = {"view": v.Name, "view_type": str(v.ViewType)}
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping")
    sub.add_parser("port")
    e = sub.add_parser("exec")
    e.add_argument("file", nargs="?", help="Python file to run (IronPython 2.7)")
    e.add_argument("-c", "--code", help="inline code instead of a file")
    e.add_argument("--tx", help="wrap in a Transaction with this name")
    e.add_argument("--rollback", action="store_true", help="with --tx: dry run, always roll back")
    e.add_argument("--fresh", action="store_true", help="reset the persistent namespace")
    e.add_argument("--args", help="JSON value exposed as `args`")
    e.add_argument("--timeout", type=float, default=300)
    e.add_argument("--raw", action="store_true", help="print Revit stdout only (no JSON)")
    s = sub.add_parser("snapshot")
    s.add_argument("out", help="output .png path")
    s.add_argument("--view", help="view name (default: active view)")
    s.add_argument("--px", type=int, default=1600)
    s.add_argument("--timeout", type=float, default=120)
    a = ap.parse_args()

    port, info = discover()
    if a.cmd == "port":
        print(port)
        return
    if a.cmd == "ping":
        info["port"] = port
        print(json.dumps(info, indent=2))
        return

    if a.cmd == "exec":
        if a.code is not None:
            code = a.code
        elif a.file == "-" or a.file is None:
            code = sys.stdin.read()
        else:
            with open(a.file, encoding="utf-8") as f:
                code = f.read()
        res = run_exec(port, code, a)
    else:  # snapshot
        d = tempfile.mkdtemp(prefix="revit_snap_")
        a.fresh = a.rollback = False
        a.tx = None
        a.args = json.dumps({"dir": d, "px": a.px, "view": a.view})
        res = run_exec(port, SNAPSHOT_CODE, a)
        if res.get("ok"):
            time.sleep(0.3)
            pngs = sorted(glob.glob(os.path.join(d, "*.png")), key=os.path.getmtime)
            if pngs:
                os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
                shutil.move(pngs[-1], a.out)
                res["image"] = os.path.abspath(a.out)
            else:
                res["ok"] = False
                res["error"] = "ExportImage produced no PNG in %s" % d

    if getattr(a, "raw", False):
        sys.stdout.write(res.get("stdout") or "")
        if not res.get("ok"):
            sys.stderr.write((res.get("traceback") or res.get("error") or "") + "\n")
    else:
        print(json.dumps(res, indent=2, ensure_ascii=False))
    sys.exit(0 if res.get("ok") else 1)


if __name__ == "__main__":
    main()
