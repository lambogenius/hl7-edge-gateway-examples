"""Stand-in for the hospital's revenue-cycle API, for sample 15: takes remittances (835) as the JSON the gateway's
x12 = "json" step makes, and prints what was paid on each claim:

  revenue: EFT20261030 PAT1001 billed 150 paid 120 patient owes 30

POST /remits takes one; GET /remits lists what it has taken.
"""
import http.server
import json

received = []


def claims(interchange):
    """(payment trace, patient control number, billed, paid, patient responsibility) for each claim."""
    for t in interchange.get("transactions", []):
        loops = t.get("loops", {})
        trace = (loops.get("TRN") or [{}])[0].get("TRN02", "")
        for lx in loops.get("2000", []):
            for c in lx.get("2100", []):
                clp = (c.get("CLP") or [{}])[0]
                yield trace, clp.get("CLP01"), clp.get("CLP03"), clp.get("CLP04"), clp.get("CLP05", "0")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/remits" or not self.headers.get("Content-Type", "").startswith("application/json"):
            return self.reply(415, {"error": "POST /remits takes application/json"})
        doc = json.loads(body)
        received.append(doc)
        for trace, claim, billed, paid, owes in claims(doc):
            print(f"revenue: {trace} {claim} billed {billed} paid {paid} patient owes {owes}", flush=True)
        self.reply(201, {"accepted": len(list(claims(doc)))})

    def do_GET(self):
        self.reply(200, received)

    def reply(self, status, doc):
        body = json.dumps(doc).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print("revenue: API on :8000", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
