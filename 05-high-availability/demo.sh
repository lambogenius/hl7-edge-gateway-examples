#!/usr/bin/env sh
# Runs every step of sample 05 and checks the result. Needs .env (see README.md).
set -eu
cd "$(dirname "$0")"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
. ./.env
# MEDITECH's view: everything goes to the one address, HAProxy on :7890.
send() { docker compose --progress quiet run --rm -T send --to lb:7890 "$@"; }
received() { curl -s http://localhost:8000/received | grep -c control_id || true; }
ready() { curl -sf "http://localhost:$1/ready" >/dev/null; }
port() { [ "$1" = gw1 ] && echo 8081 || echo 8082; }
# delivering: the node that holds the route's in-flight message (from gw<n>'s admin API)
delivering() {
  curl -s -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" "http://localhost:$(port "$1")/api/overview" |
    python3 -c "import json,sys; print(next((n['node_id'] for n in json.load(sys.stdin)['nodes'] for r in n['routes'] if r['dispatch'] in ('delivering','retrying')), ''))"
}
wait_received() { for i in $(seq 1 "$2"); do [ "$(received)" -ge "$1" ] && return 0; sleep 1; done; return 1; }

step "Starting 3 NATS nodes, 2 gateway nodes, HAProxy and the lab API"
docker compose --progress quiet up -d
echo "Waiting for the JetStream cluster and both gateways (about a minute the first time)..."
for i in $(seq 1 120); do ready 8081 && ready 8082 && break; sleep 1; done
ready 8081 && ready 8082 || fail "the gateways are not ready; see: docker compose logs gw1 gw2"
sleep 5   # let HAProxy see both as up

step "1. MEDITECH sends three results through HAProxy"
send /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7 /messages/oru-r01-3.hl7
wait_received 3 15 || fail "3 results should be delivered"
echo "Delivered: $(received)"

step "2. The lab API goes down; three more results are queued in JetStream"
curl -s -X POST http://localhost:8000/control/down >/dev/null
send /messages/oru-r01-4.hl7 /messages/oru-r01-5.hl7 /messages/oru-r01-6.hl7
node=""
for i in $(seq 1 30); do   # node status comes from heartbeats, every few seconds
  node=$(delivering gw1); [ -n "$node" ] || node=$(delivering gw2)
  [ -n "$node" ] && break
  sleep 1
done
[ -n "$node" ] || fail "one node should be retrying the route"
echo "Queued on all three NATS nodes; $node holds the route's in-flight message."

step "3. $node crashes, then the lab API comes back"
docker compose kill "$node" >/dev/null 2>&1
start=$(date +%s)
curl -s -X POST http://localhost:8000/control/up >/dev/null
wait_received 6 90 || fail "the other node should deliver the queued results"
echo "The other node delivered all of them $(( $(date +%s) - start ))s later (within ack_wait = 30 s), in order:"
curl -s http://localhost:8000/received | grep control_id | tail -3
docker compose --progress quiet start "$node"
for i in $(seq 1 60); do ready "$(port "$node")" && break; sleep 1; done
sleep 5

step "4. gw1, the node HAProxy sends MEDITECH to, crashes"
docker compose kill gw1 >/dev/null 2>&1
sleep 5   # HAProxy notices within about 4 s
send /messages/oru-r01-7.hl7
wait_received 7 20 || fail "LAB-1007 should be delivered through gw2"
echo "HAProxy moved MEDITECH to gw2; LAB-1007 delivered."

step "5. A NATS node crashes too (the queue has 3 replicas, so 2 are enough)"
docker compose kill nats1 >/dev/null 2>&1
sleep 3
send /messages/oru-r01-8.hl7
wait_received 8 30 || fail "LAB-1008 should be delivered with one NATS node down"
echo "LAB-1008 delivered with gw1 and nats1 both down."

step "6. Everything comes back"
docker compose --progress quiet start nats1 gw1
for i in $(seq 1 60); do ready 8081 && break; sleep 1; done
sleep 5
send /messages/oru-r01-9.hl7
wait_received 9 20 || fail "LAB-1009 should be delivered"
ids=$(curl -s http://localhost:8000/received | grep -o 'LAB-10[0-9]*' | tr '\n' ' ')
echo "The lab API received, in this order: $ids"
[ "$ids" = "LAB-1001 LAB-1002 LAB-1003 LAB-1004 LAB-1005 LAB-1006 LAB-1007 LAB-1008 LAB-1009 " ] ||
  fail "expected LAB-1001 to LAB-1009 once each, in order"
echo "Nine results, each delivered once, in order, through two node crashes and a NATS crash."

step "Done. Consoles: http://localhost:8081 (gw1), http://localhost:8082 (gw2). Clean up with: docker compose down -v"
