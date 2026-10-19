# 05 · High availability

Two gateway nodes behind one address, with the queue in a three-node NATS JetStream cluster. A gateway
node can crash, and so can one NATS node, without losing a message, delivering one twice, or changing
the order.

```
                                   ┌─────────────┐
MEDITECH ──MLLP──▶ HAProxy :7890 ─▶│ gw1 (active)│──┐                       ┌──────────┐
                   (one address)   └─────────────┘  │  HTTP, in order       │          │
                        │          ┌─────────────┐  ├──────────────────────▶│ lab API  │
                        └ ─ ─ ─ ─ ▶│ gw2 (standby│──┘  one message in       │          │
                         if gw1 is │  for MLLP)  │     flight per route     └──────────┘
                         not ready └─────────────┘
                                     │  queue: JetStream stream, 3 replicas │
                               ┌─────┴──────┬────────────┬─────────────────┘
                             nats1        nats2        nats3
```

How it works:
- **Receiving.** HAProxy sends every MLLP connection to gw1 while gw1 is ready, and to gw2 otherwise
  (`balance first`). The gateway acknowledges a message only after JetStream has stored it on a majority of
  the NATS nodes.
- **Delivering.** Each route's queue is one JetStream stream. Across the cluster exactly one message per
  route is in flight at a time, and whichever gateway node is free delivers the next one. Order is kept
  even when nodes take turns.
- **Failover.** A message that was in flight on a crashed node is delivered by another node after
  `ack_wait` (30 s here). New connections move to the other node as soon as HAProxy's health check fails
  (about 4 s). MEDITECH reconnects and resends anything it did not get an ACK for.
- **Quorum.** With three NATS nodes and three replicas, the queue keeps working with any one NATS node
  down.

Step-by-step guide with screenshots: <https://docs.lambogenius.com/hl7-edge-gateway/examples/high-availability>

## Files

| File | What it is |
|---|---|
| `gateway.toml` | The configuration every gateway node uses; only `HL7EDGE_NODE_ID` differs |
| `compose.yaml` | 3 NATS nodes, 2 gateway nodes, HAProxy, and the stand-in lab API from sample 01 |
| `haproxy/haproxy.cfg` | Active/passive TCP load balancing with health checks on `/ready` |
| `lab-api/app.py`, `messages/` | The stand-in lab API and nine test results |
| `demo.sh` | Runs the failure scenario below and checks the result |

## Run it

You need Docker, the gateway image, and a license. See [the prerequisites](../README.md#prerequisites).
Every node uses the same license.

```sh
cp .env.example .env          # then put your license in LAMBOGENIUS_LICENSE
docker compose up -d
```

The first start takes about a minute while the NATS nodes form the JetStream cluster. The gateways log
`store not available yet, retrying` until it is ready. Both consoles show the whole cluster:
<http://localhost:8081> (gw1) and <http://localhost:8082> (gw2). Their **Nodes** table lists both gateways and
which one is delivering.

Then run `./demo.sh`, or follow the steps:

| Step | Command | What to look for |
|---|---|---|
| 1. Normal traffic | `docker compose run --rm send --to lb:7890 /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7 /messages/oru-r01-3.hl7` | 3 delivered (`curl localhost:8000/received`). |
| 2. Lab API down | `curl -X POST localhost:8000/control/down`, then send `oru-r01-4` to `-6` | 3 queued. The **Nodes** table shows which node is delivering (`lab-results #4`). |
| 3. That node crashes | `docker compose kill gw2` (or `gw1`), then `curl -X POST localhost:8000/control/up` | The other node delivers LAB-1004 to LAB-1006 within `ack_wait`, in order. |
| 4. gw1 crashes | `docker compose start gw2`, then `docker compose kill gw1`, then send `oru-r01-7` | HAProxy moves MEDITECH to gw2; LAB-1007 is delivered. |
| 5. A NATS node crashes | `docker compose kill nats1`, then send `oru-r01-8` | Still delivered: two of three replicas are enough. |
| 6. Recovery | `docker compose start nats1 gw1`, then send `oru-r01-9` | gw1 is active again. The lab API has LAB-1001 to LAB-1009, each once, in order. |

**Clean up:** `docker compose down -v`.

## Taking it to production

- **Hosts.** Run the three NATS nodes on three separate machines or VMs (or availability zones), and the
  two gateways on two of them or on separate ones. Three NATS nodes are the minimum for quorum: with two,
  losing one stops the queue.
- **The one address.** Use what your network already has: a load balancer VIP (F5, NetScaler, HAProxy with
  keepalived), or in the cloud a TCP load balancer (Azure Load Balancer, AWS NLB, Google Cloud TCP LB). Keep
  it active/passive (gw1 first), health-checked on `GET /ready` on the admin port, and have it close the
  connections of a node it marks down. Samples [06 to 09](../README.md) show this on-premises and in each cloud.
- **DNS in the load balancer.** If it addresses the gateways by name, make sure it re-resolves names: a
  replaced node or container can come back with a different IP address. This sample's `haproxy.cfg` uses
  Docker's DNS server for that (`resolvers docker`).
- **NATS version.** Use NATS Server 2.15.1 or later (this sample is tested with 2.15.1). In the crash
  test of [sample 06](../06-on-premises/test) with 2.11.17, the NATS server on the crashed host came back, logged `Detected orphaned
  stream`, and deleted its copies of the queue streams. It never got them back, so those streams were left
  with two replicas without any error. Check after any host restart:
  `curl -s 'localhost:8222/jsz?streams=true'` should list the same streams, with the same `last_seq`, on
  every host.
- **Secure NATS.** Use `tls://` URLs with `ca` (and `client_cert`/`client_key` for mutual TLS), and a
  `credentials_file`, `token` or `user`/`password`. The queue holds PHI.
- **ack_wait.** A shorter `ack_wait` means a faster takeover after a crash. It must stay above the longest
  delivery attempt: `request_timeout` + 5 s (the gateway checks this at startup).
- **Monitoring.** Scrape `/metrics` from every node. `hl7edge_queue_depth` and `hl7edge_dead_letters` are
  cluster-wide; alert on a growing depth and on any dead letter.
