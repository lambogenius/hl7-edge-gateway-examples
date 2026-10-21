"""Stand-ins for the patient portal's API and the research registry (Python standard library only).

  POST /patients   the portal's API: takes JSON, needs "Authorization: Bearer <PORTAL_API_TOKEN>"
  POST /research   the research registry: takes HL7
  GET  /received   what each has accepted, with its content type, as JSON
"""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("PORTAL_API_TOKEN", "")
received = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/received":
            return self.reply(404, "not found")
        with lock:
            self.reply(200, json.dumps(received, indent=2), "application/json")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        content_type = self.headers.get("Content-Type", "")
        if self.path == "/patients":
            if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                return self.reply(401, "missing or wrong token")
            try:
                doc = json.loads(body)
            except ValueError:
                return self.reply(400, "not JSON")
            entry = {"system": "patient-api", "content_type": content_type, "body": doc}
            print(f"patient-api: {doc.get('event')} {doc.get('patient', {}).get('mrn')} ({content_type})", flush=True)
        elif self.path == "/research":
            segments = [s for s in body.replace("\n", "\r").split("\r") if s]
            entry = {"system": "research", "content_type": content_type, "body": segments}
            pid = next((s for s in segments if s.startswith("PID|")), "")
            print(f"research: {pid[:60]}…", flush=True)
        else:
            return self.reply(404, "not found")
        with lock:
            received.append(entry)
        self.reply(200, "accepted")

    def reply(self, status: int, text: str, content_type: str = "text/plain"):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


print("systems: patient-api and research on :8000", flush=True)
ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
