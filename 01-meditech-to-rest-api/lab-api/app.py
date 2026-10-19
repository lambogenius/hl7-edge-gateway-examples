"""A stand-in for the lab's REST API (Python standard library only).

  POST /hl7/results     accepts an ORU^R01, unless it has no patient ID (PID-3.1): then 422
  POST /hl7/admissions  accepts ADT events
  POST /control/down    the API starts answering 503 (simulates an outage)
  POST /control/up      back to normal
  GET  /received        what it has accepted, as JSON

Every request must carry "Authorization: Bearer <LAB_API_TOKEN>".
"""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("LAB_API_TOKEN", "")
state = {"down": False, "received": []}
lock = threading.Lock()


def field(message: str, segment: str, index: int) -> str:
    for line in message.replace("\n", "\r").split("\r"):
        parts = line.split("|")
        if parts[0] == segment:
            # MSH-1 is the separator itself, so MSH fields are shifted by one.
            i = index - 1 if segment == "MSH" else index
            return parts[i] if len(parts) > i else ""
    return ""


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
            print(f"lab-api: {'DOWN (answering 503)' if state['down'] else 'back UP'}", flush=True)
            return self.reply(200, "ok")
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.reply(401, "missing or wrong token")
        if state["down"]:
            return self.reply(503, "lab API is down for maintenance")
        control_id, msg_type = field(body, "MSH", 10), field(body, "MSH", 9)
        if self.path == "/hl7/results" and not field(body, "PID", 3).split("^")[0]:
            print(f"lab-api: REJECTED {control_id} {msg_type}: no patient ID", flush=True)
            return self.reply(422, "PID-3.1 (patient ID) is required")
        if self.path not in ("/hl7/results", "/hl7/admissions"):
            return self.reply(404, "not found")
        with lock:
            state["received"].append({"path": self.path, "control_id": control_id, "type": msg_type})
        print(f"lab-api: accepted {control_id} {msg_type} on {self.path}", flush=True)
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


print("lab-api: listening on :8000", flush=True)
ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
