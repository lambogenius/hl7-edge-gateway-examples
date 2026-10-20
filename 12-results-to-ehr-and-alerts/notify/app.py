"""A stand-in for a notification service: the on-call pager, or infection control (Python standard library only).

  POST /alerts        takes an ORU^R01 and prints what it would notify: each order with its flagged results
  POST /control/down  the service starts answering 503 (simulates an outage)
  POST /control/up    back to normal
  GET  /received      what it has accepted, as JSON

Every POST /alerts must carry "Authorization: Bearer <NOTIFY_API_TOKEN>". SERVICE names it in the log.
"""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = os.environ.get("SERVICE", "notify")
TOKEN = os.environ.get("NOTIFY_API_TOKEN", "")
state = {"down": False, "received": []}
lock = threading.Lock()


def segments(message: str):
    return [line.split("|") for line in message.replace("\n", "\r").split("\r") if line]


def summary(message: str) -> dict:
    """The control ID, the patient, and each order's test with its flagged results."""
    out = {"control_id": "", "patient": "", "orders": []}
    for s in segments(message):
        get = lambda i: s[i] if len(s) > i else ""
        if s[0] == "MSH":
            out["control_id"] = s[9] if len(s) > 9 else ""
        elif s[0] == "PID":
            out["patient"] = get(3).split("^")[0]
        elif s[0] == "OBR":
            out["orders"].append({"test": get(4).split("^")[0], "flagged": []})
        elif s[0] == "OBX" and out["orders"] and get(8) not in ("", "N"):
            out["orders"][-1]["flagged"].append(f"{get(3).split('^')[0]} {get(5)} {get(6)} {get(8)}".replace("  ", " "))
    return out


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/received":
            with lock:
                return self.reply(200, json.dumps(state["received"], indent=2))
        self.reply(404, "not found")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        if self.path in ("/control/down", "/control/up"):
            state["down"] = self.path.endswith("down")
            print(f"{NAME}: {'DOWN (answering 503)' if state['down'] else 'back UP'}", flush=True)
            return self.reply(200, "ok")
        if self.path != "/alerts":
            return self.reply(404, "not found")
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.reply(401, "missing or wrong token")
        if state["down"]:
            return self.reply(503, f"{NAME} is down for maintenance")
        alert = summary(body)
        with lock:
            state["received"].append(alert)
        flagged = "; ".join(f"{o['test']}: {', '.join(o['flagged'])}" for o in alert["orders"] if o["flagged"])
        print(f"{NAME}: {alert['control_id']} patient {alert['patient']}: {flagged}", flush=True)
        self.reply(200, "accepted")

    def reply(self, status: int, text: str):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json" if text.startswith(("[", "{")) else "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


print(f"{NAME}: listening on :8000", flush=True)
ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
