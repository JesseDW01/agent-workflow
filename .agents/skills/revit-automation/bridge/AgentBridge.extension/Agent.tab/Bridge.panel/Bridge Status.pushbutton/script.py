# -*- coding: utf-8 -*-
"""Show Agent Bridge status (routes server, port, token file)."""
import os
from pyrevit import forms
from pyrevit.userconfig import user_config
from pyrevit.routes.server import serverinfo

token_file = os.path.join(os.environ.get("APPDATA", ""), "pyRevit", "agent_bridge_token.txt")
lines = [
    "Routes server enabled: {}".format(user_config.routes_server),
    "Configured base port: {}".format(user_config.routes_port),
    "Token file: {} ({})".format(token_file, "present" if os.path.exists(token_file) else "MISSING"),
]
try:
    info = serverinfo.get_registered_servers()
    for s in info:
        lines.append("Revit {} pid {} -> {}:{}".format(s.version, s.process_id, s.server_host, s.server_port))
except Exception as ex:
    lines.append("Could not list servers: {}".format(ex))
lines.append("")
lines.append("Endpoints: POST /agent/ping , POST /agent/exec")
lines.append("If disabled: run 'pyrevit configs routes enable' and restart Revit.")
forms.alert("\n".join(lines), title="Agent Bridge")
