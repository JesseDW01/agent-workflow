# -*- coding: utf-8 -*-
"""Agent Bridge - lets a local agent run Python inside the LIVE Revit session.

Loaded by pyRevit at startup. Registers pyRevit Routes endpoints:

    POST http://127.0.0.1:<port>/agent/ping   {"token": "..."}
    POST http://127.0.0.1:<port>/agent/exec   {"token": "...", "code": "...", ...}

Handlers run on Revit's main thread through an ExternalEvent (full API
context, same as a button click). Port starts at the pyRevit routes port
(default 48884) and increments per running Revit instance.

Requires:  pyrevit configs routes enable   (then restart Revit)
Client:    scripts/revit_bridge.py in the revit-automation skill.

IronPython 2.7 - keep this file PY2/PY3 compatible (no f-strings).
"""
import os
import sys
import json
import time
import traceback

from System import Guid

from pyrevit import routes
from pyrevit.api import DB, UI

try:
    from StringIO import StringIO  # IronPython 2.7
except ImportError:
    from io import StringIO

BRIDGE_VERSION = "1.0.0"
API = routes.API("agent")

TOKEN_FILE = os.path.join(os.environ.get("APPDATA", ""), "pyRevit",
                          "agent_bridge_token.txt")


def _load_or_create_token():
    try:
        if os.path.exists(TOKEN_FILE):
            with open(TOKEN_FILE, "r") as f:
                tok = f.read().strip()
            if tok:
                return tok
        tok = Guid.NewGuid().ToString("N")
        with open(TOKEN_FILE, "w") as f:
            f.write(tok)
        return tok
    except Exception:
        # never let the bridge break pyRevit startup
        return None


TOKEN = _load_or_create_token()

# Persistent namespace across /exec calls (like a REPL). Reset with "fresh".
_SESSION = {}


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def _deny(msg, status=401):
    return routes.make_response({"ok": False, "error": msg}, status=status)


def _check(request):
    data = request.data
    if isinstance(data, (bytes, str)) and not isinstance(data, dict):
        try:
            data = json.loads(data)
        except Exception:
            data = None
    if not isinstance(data, dict):
        return None, _deny("Body must be JSON with Content-Type: application/json", 400)
    if TOKEN is None or data.get("token") != TOKEN:
        return None, _deny("Bad or missing token (see %s)" % TOKEN_FILE)
    return data, None


def _jsonable(obj, depth=0):
    """Best-effort conversion of Revit/.NET objects to JSON-safe values."""
    if depth > 6:
        return str(obj)
    if obj is None or isinstance(obj, (bool, int, float)):
        return obj
    try:
        if isinstance(obj, long):  # noqa: F821  (IronPython 2)
            return int(obj)
    except NameError:
        pass
    if isinstance(obj, (str, type(u""))):
        return obj
    if isinstance(obj, DB.ElementId):
        return obj.Value
    if isinstance(obj, DB.XYZ):
        return [obj.X, obj.Y, obj.Z]
    if isinstance(obj, dict):
        return dict((str(k), _jsonable(v, depth + 1)) for k, v in obj.items())
    if isinstance(obj, (list, tuple, set)):
        return [_jsonable(v, depth + 1) for v in obj]
    if isinstance(obj, DB.Element):
        return {"id": obj.Id.Value, "name": getattr(obj, "Name", None),
                "category": obj.Category.Name if obj.Category else None,
                "class": obj.GetType().Name}
    # other .NET enumerables (List<T>, ICollection, ...)
    if hasattr(obj, "GetEnumerator") and not isinstance(obj, (str, type(u""))):
        try:
            return [_jsonable(v, depth + 1) for v in obj]
        except Exception:
            pass
    return str(obj)


class _SwallowWarnings(DB.IFailuresPreprocessor):
    """Deletes warnings and rolls back on errors so NO modal dialog appears.

    A modal failure dialog would block Revit and hang every later request.
    Collected messages are reported back to the agent.
    """

    def __init__(self, sink):
        self.sink = sink

    def PreprocessFailures(self, accessor):
        has_error = False
        for f in accessor.GetFailureMessages():
            sev = f.GetSeverity()
            self.sink.append("%s: %s" % (sev, f.GetDescriptionText()))
            if sev == DB.FailureSeverity.Warning:
                accessor.DeleteWarning(f)
            else:
                has_error = True
        if has_error:
            return DB.FailureProcessingResult.ProceedWithRollBack
        return DB.FailureProcessingResult.Continue


def _attach_quiet(t, sink):
    opts = t.GetFailureHandlingOptions()
    opts.SetFailuresPreprocessor(_SwallowWarnings(sink))
    opts.SetClearAfterRollback(True)
    t.SetFailureHandlingOptions(opts)
    return t


class Tx(object):
    """Context manager for agent code that wants its own transaction(s).

        with Tx("Make walls"):
            DB.Wall.Create(doc, ...)

    Commits on success, rolls back on exception, swallows warning dialogs.
    """

    def __init__(self, name, document=None):
        self.name = name
        self.doc = document or _SESSION.get("doc")
        self.t = None

    def __enter__(self):
        self.t = _attach_quiet(DB.Transaction(self.doc, self.name),
                               _SESSION.setdefault("failures", []))
        self.t.Start()
        return self.t

    def __exit__(self, exc_type, exc, tb):
        if exc_type is not None:
            if self.t.HasStarted() and not self.t.HasEnded():
                self.t.RollBack()
            return False
        status = self.t.Commit()
        if status != DB.TransactionStatus.Committed:
            raise Exception("Transaction '%s' ended with status %s (failures: %s)"
                            % (self.name, status, _SESSION.get("failures")))
        return False


# --------------------------------------------------------------------------
# routes
# --------------------------------------------------------------------------
@API.route("/ping", methods=["POST"])
def ping(request, uiapp):
    data, err = _check(request)
    if err:
        return err
    uidoc = uiapp.ActiveUIDocument
    doc = uidoc.Document if uidoc else None
    return {
        "ok": True,
        "bridge_version": BRIDGE_VERSION,
        "revit_version": uiapp.Application.VersionNumber,
        "revit_build": uiapp.Application.VersionBuild,
        "python": sys.version,
        "active_doc": doc.Title if doc else None,
        "active_doc_path": doc.PathName if doc else None,
        "is_family_doc": doc.IsFamilyDocument if doc else None,
        "active_view": doc.ActiveView.Name if doc and doc.ActiveView else None,
        "open_docs": [d.Title for d in uiapp.Application.Documents],
        "session_vars": sorted(k for k in _SESSION.keys() if not k.startswith("__")),
    }


@API.route("/exec", methods=["POST"])
def execute(request, uiapp):
    """Run agent Python in the live session.

    Body fields:
      code        (str, required) Python source. IronPython 2.7.
      transaction (str, optional) wrap the whole run in a Transaction with
                  this name (warnings auto-deleted, errors roll back).
      rollback    (bool) with transaction: always roll back (dry run).
      fresh       (bool) start from an empty namespace.
      args        (any)  exposed to the code as `args`.

    Namespace provided to the code:
      uiapp, app, uidoc, doc, DB, UI, Tx, args, result (set it to return data)
      plus anything defined by earlier calls (persistent unless fresh=true).
    """
    data, err = _check(request)
    if err:
        return err
    code = data.get("code")
    if not code:
        return _deny("Missing 'code'", 400)

    if data.get("fresh"):
        _SESSION.clear()

    uidoc = uiapp.ActiveUIDocument
    doc = uidoc.Document if uidoc else None
    failures = []
    _SESSION.update({
        "uiapp": uiapp, "app": uiapp.Application, "uidoc": uidoc, "doc": doc,
        "DB": DB, "UI": UI, "Tx": Tx, "args": data.get("args"),
        "result": None, "failures": failures, "__name__": "__agent__",
    })

    buf = StringIO()
    old_out, old_err = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = buf
    t = None
    ok = True
    error = None
    tb = None
    tx_status = None
    started = time.time()
    try:
        tx_name = data.get("transaction")
        if tx_name:
            if doc is None:
                raise Exception("No active document for transaction")
            t = _attach_quiet(DB.Transaction(doc, tx_name), failures)
            t.Start()
        exec(compile(code, "<agent>", "exec"), _SESSION)
        if t is not None:
            if data.get("rollback"):
                t.RollBack()
                tx_status = "RolledBack (dry run)"
            else:
                tx_status = str(t.Commit())
                if tx_status != "Committed":
                    ok = False
                    error = "Transaction status: %s" % tx_status
    except BaseException as ex:  # noqa - .NET exceptions included
        ok = False
        error = "%s: %s" % (type(ex).__name__, ex)
        tb = traceback.format_exc()
        if t is not None and t.HasStarted() and not t.HasEnded():
            t.RollBack()
            tx_status = "RolledBack (error)"
    finally:
        sys.stdout, sys.stderr = old_out, old_err

    try:
        result = _jsonable(_SESSION.get("result"))
    except Exception as ex:
        result = "<unserializable result: %s>" % ex

    return {
        "ok": ok,
        "stdout": buf.getvalue(),
        "result": result,
        "error": error,
        "traceback": tb,
        "transaction": tx_status,
        "failures": list(failures),
        "seconds": round(time.time() - started, 3),
        "active_doc": doc.Title if doc else None,
    }
