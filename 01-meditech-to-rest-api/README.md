# 01 · MEDITECH → REST API

MEDITECH sends lab results (ORU^R01) and admissions (ADT^A01) over MLLP. HL7 Edge Gateway
acknowledges them and posts each one to a lab system's REST API with a bearer token.

```
MEDITECH ──MLLP :7890──▶ ┌───────────────────────┐ ──POST /hl7/results───▶ ┌─────────┐
 (results)               │   HL7 Edge Gateway    │   store and forward      │ lab API │
MEDITECH ──MLLP :7891──▶ │ admin console :8080   │ ──POST /hl7/admissions─▶ │  :8000  │
 (admissions)            └───────────────────────┘   pass-through           └─────────┘
```

The sample shows both delivery modes:

| Route | Mode | What MEDITECH sees |
|---|---|---|
| `lab-results` | store and forward | `AA` as soon as the result is stored on disk. The gateway delivers in order and keeps retrying while the API is down. A result the API rejects is moved to dead letters, and the rest keep flowing. |
| `admissions` | pass-through | The API's own answer. Nothing is stored: if the API is down, MEDITECH gets `AE` and resends. |

Step-by-step guide with screenshots: <https://docs.lambogenius.com/hl7-edge-gateway/examples/meditech-to-rest-api>

## Files

| File | What it is |
|---|---|
| `gateway.toml` | The gateway configuration: two routes, admin console, embedded store |
| `compose.yaml` | The gateway, a stand-in lab API, and a `send` tool (the gateway's own MLLP test client) |
| `lab-api/app.py` | The stand-in lab API (Python standard library). Rejects a result without a patient ID with HTTP 422; can be switched to answer 503 |
| `messages/` | Test messages: five results, one result without a patient ID, two admissions. All are marked as test messages (MSH-11 = `T`) |
| `.env.example` | Settings and secrets; copy it to `.env` |
| `demo.sh`, `demo.ps1` | Runs every step below and checks the result |

## Run it

You need Docker, the gateway image, and a license (a free developer license works). See
[the prerequisites](../README.md#prerequisites).

```sh
cp .env.example .env          # then put your license in LAMBOGENIUS_LICENSE
docker compose up -d
```

Open the admin console at <http://localhost:8080> and sign in with `HL7EDGE_ADMIN_TOKEN` from `.env`.

**1. Send three results and an admission.**

```sh
docker compose run --rm send --to gateway:7890 /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7 /messages/oru-r01-3.hl7
docker compose run --rm send --to gateway:7891 /messages/adt-a01.hl7
curl http://localhost:8000/received
```

Each message gets `MSA|AA|<control id>`, and the lab API lists all four.

**2. Take the API down and keep sending.**

```sh
curl -X POST http://localhost:8000/control/down
docker compose run --rm send --to gateway:7890 /messages/oru-r01-4.hl7 /messages/oru-r01-5.hl7
```

MEDITECH still gets `AA`: the results are safe in the gateway's queue. In the console,
`lab-results` shows **retrying**, two queued, and `HTTP 503` as its last error. Retries back off from
2 s up to 30 s.

Pass-through behaves differently. An admission sent now gets the outage back:

```sh
docker compose run --rm send --to gateway:7891 /messages/adt-a08.hl7
#    1       4 ms  MSA|AE|ADT-2002|HTTP 503
```

MEDITECH keeps the message and resends it later. Nothing is stored in the gateway.

**3. Bring the API back.**

```sh
curl -X POST http://localhost:8000/control/up
```

Within 30 seconds the queue drains in order (LAB-1004, then LAB-1005), with no resend from MEDITECH.

**4. Send a result the API rejects.**

```sh
docker compose run --rm send --to gateway:7890 /messages/oru-r01-no-patient-id.hl7
docker compose logs lab-api
```

The API answers `422` (no patient ID), so retrying would not help. The gateway moves LAB-1099 to
**dead letters** and carries on. In the console, open `lab-results` → **Dead letters** → **View** to see the
message and the reason. After fixing it, you can requeue or delete it there.

**Clean up:** `docker compose down -v` (`-v` also deletes the queue volume).

Or run everything with `./demo.sh` (Linux, macOS, WSL) or `./demo.ps1` (Windows PowerShell).

## Adapting it to your site

- **Point MEDITECH at the gateway.** Set the MEDITECH outbound interface for lab results to the gateway host,
  port 7890, and admissions to port 7891.
- **Use your API.** Set `url` and `headers` in `gateway.toml`. For a real HTTPS API, use `https://…`. If its
  certificate comes from a private CA, add `tls = { ca = "/etc/hl7-edge-gateway/ca.pem" }` to the destination.
  If the API uses OAuth2 instead of a static token, see [sample 04](../04-entra-id-and-salesforce).
- **Encrypt the MLLP leg.** Add `tls = { cert = "…", key = "…" }` to the source to listen with MLLPS.
- **Live messages.** A developer license only accepts test messages (MSH-11 `T` or `D`). Production traffic
  (`P`) needs a trial or production license.
- **Keep the queue.** The `queue` volume holds messages that have not been delivered yet. Do not delete it
  while messages are queued.
