# HL7 Edge Gateway examples

Complete, runnable sample solutions for [Lambogenius HL7 Edge Gateway](https://lambogenius.com). Each
folder has:
- the full configuration, with comments;
- a stand-in for every system it talks to;
- test messages;
- a script that runs each step and checks the result;
- architecture, data flow and sequence diagrams (Mermaid sources, exported as PNG, in `diagrams/`).

Step-by-step guides with screenshots: <https://docs.lambogenius.com/hl7-edge-gateway/examples>

| Sample | What it shows | Runs on |
|---|---|---|
| [01 · MEDITECH → REST API](01-meditech-to-rest-api) | MLLP in, HTTPS REST out with a bearer token. Store-and-forward through an API outage, dead letters, and pass-through | Docker |
| [02 · Partners → MEDITECH](02-partners-to-meditech) | HTTPS REST with an API key per partner and SOAP with basic auth, into MEDITECH over MLLP | Docker |
| [03 · Azure Service Bus](03-azure-service-bus) | MEDITECH to a topic with two subscriptions, and a queue to MEDITECH; outages on both sides | Docker (Service Bus emulator); notes for a real namespace |
| [04 · Entra ID and Salesforce](04-entra-id-and-salesforce) | Only callers with an Entra ID token and app role get in; results go to Salesforce with the JWT bearer flow | Docker, plus your Entra ID tenant and Salesforce org |
| [05 · High availability](05-high-availability) | 3 NATS JetStream nodes, 2 gateways, and HAProxy. Node crashes with nothing lost, duplicated or reordered | Docker |
| [06 · On-premises HA](06-on-premises) | Linux VMs with systemd, NATS over mutual TLS, and a keepalived virtual IP, plus a harness that tests the same files on three simulated hosts | VMs (harness: Docker) |
| [07 · Azure (AKS)](07-azure-aks) | Three zones, internal Azure Load Balancer, Premium SSD, ACR | Azure |
| [08 · AWS (EKS)](08-aws-eks) | Three AZs, internal NLB with `/ready` health checks, encrypted gp3, ECR | AWS |
| [09 · Google Cloud (GKE)](09-gcp-gke) | Regional cluster, internal passthrough load balancer, pd-ssd, Artifact Registry | Google Cloud |

Samples 07–09 share one Kubernetes base, [`shared/kubernetes`](shared/kubernetes), which is tested on k3s.

## Prerequisites

1. **Docker** with Compose v2 (Docker Desktop on Windows or macOS, or Docker Engine on Linux).
2. **The gateway image.** Sign in at <https://lambogenius.com/downloads>, download
   `hl7-edge-gateway-<version>-docker-image-linux-amd64.tar.gz`, and load it:
   ```sh
   docker load -i hl7-edge-gateway-0.3.0-docker-image-linux-amd64.tar.gz
   ```
   The archive is signed. To check it first, see the gateway's
   [Quick start](https://docs.lambogenius.com/hl7-edge-gateway/quick-start).
3. **A license.** A free developer license works for every sample: they all send test messages (MSH-11 =
   `T`). Get one at <https://lambogenius.com/app/licensing>. Put it in each sample's `.env`, as
   `LAMBOGENIUS_LICENSE=…`.

Every sample starts the same way:

```sh
cd 01-meditech-to-rest-api
cp .env.example .env        # put your license in it
docker compose up -d
./demo.sh                   # or .\demo.ps1 in Windows PowerShell (samples 01-04)
docker compose down -v      # when you are done
```

The samples use the same ports (7890, 8080, 8443…), so run one at a time.

## Conventions

- `.env` holds the license and secrets and is ignored by git; `.env.example` lists what goes in it.
- `${NAME}` in `gateway.toml` is replaced with the environment variable `NAME`.
- The admin console is at <http://localhost:8080>. Sign in with `HL7EDGE_ADMIN_TOKEN` from `.env`.
- `docker compose run --rm send --to gateway:7890 /messages/<file>` uses the gateway's own MLLP test client.
- Diagrams: edit `<sample>/diagrams/*.mmd`, then run `./render-diagrams.sh <sample>` (Docker) to re-export the
  PNGs. `mermaid-config.json` sets their look.
