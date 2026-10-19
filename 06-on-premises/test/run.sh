#!/usr/bin/env sh
# Failover test for sample 06 on three simulated hosts (see compose.yaml), with the sample's own files.
set -eu
cd "$(dirname "$0")"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
# on <host> <command>: run a command on a simulated host (in its network namespace)
on() { h=$1; shift; docker compose exec -T "keepalived${h#edge}" "$@"; }
ready() { on "$1" curl -sf -m 2 -o /dev/null http://127.0.0.1:8080/ready; }
vip_on() { on "$1" ip -o -4 addr show eth0 2>/dev/null | grep -q '10.0.10.10/'; }
# send: like MEDITECH, reconnect if the connection cannot be made (for a moment after the VIP moves,
# the network may not know its new MAC address yet). Nothing was sent then, so retrying is safe.
send() {
  for attempt in 1 2 3 4 5; do
    out=$(docker compose --progress quiet run --rm -T send --to 10.0.10.10:7890 "$@" 2>&1) && { echo "$out"; return 0; }
    echo "$out" | grep -q "Error: connecting" || { echo "$out"; return 1; }
    sleep 2
  done
  echo "$out"; return 1
}
received() { on edge2 curl -s http://10.0.10.20:8000/received | grep -c control_id || true; }
wait_for() { n=$1; shift; for i in $(seq 1 "$n"); do "$@" && return 0; sleep 1; done; return 1; }
host_down() { docker compose kill "keepalived${1#edge}" "gw${1#edge}" "nats${1#edge}" "$1" >/dev/null 2>&1; }
host_up() { docker compose --progress quiet start "$1" "nats${1#edge}" "gw${1#edge}" "keepalived${1#edge}"; }

[ -f ../certs/edge3/server.crt ] || ../certs/make-certs.sh

step "Starting three hosts"
docker compose --progress quiet build
docker compose --progress quiet up -d
wait_for 120 ready edge1 || fail "the gateway on edge1 is not ready: docker compose logs gw1"
wait_for 60 ready edge2 || fail "the gateway on edge2 is not ready: docker compose logs gw2"
echo "NATS JetStream: $(on edge1 curl -s http://127.0.0.1:8222/jsz | grep -o '"cluster_size": *[0-9]*' | head -1); gateways ready on edge1 and edge2."
wait_for 20 vip_on edge1 || fail "the VIP should be on edge1"
echo "VIP 10.0.10.10 is on edge1."

step "1. MEDITECH sends two results to the VIP"
send /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7
wait_for 15 sh -c "[ \$(docker compose exec -T keepalived2 curl -s http://10.0.10.20:8000/received | grep -c control_id) -ge 2 ]" || fail "2 results should be delivered"
echo "Delivered: $(received)"

step "2. edge1 fails (gateway, NATS and keepalived all stop)"
host_down edge1
start=$(date +%s)
wait_for 30 vip_on edge2 || fail "the VIP should move to edge2"
echo "VIP moved to edge2 after $(( $(date +%s) - start ))s."
wait_for 30 ready edge2 || fail "edge2 should stay ready with NATS on edge2 and edge3"
send /messages/oru-r01-3.hl7 /messages/oru-r01-4.hl7
wait_for 30 sh -c "[ \$(docker compose exec -T keepalived2 curl -s http://10.0.10.20:8000/received | grep -c control_id) -ge 4 ]" || fail "results 3 and 4 should be delivered through edge2"
echo "Delivered: $(received), through edge2, with NATS on two of three hosts."

step "3. edge1 comes back"
host_up edge1
wait_for 120 ready edge1 || fail "the gateway on edge1 should be ready again"
wait_for 30 vip_on edge1 || fail "the VIP should move back to edge1"
echo "VIP is back on edge1."
send /messages/oru-r01-5.hl7 /messages/oru-r01-6.hl7
wait_for 30 sh -c "[ \$(docker compose exec -T keepalived2 curl -s http://10.0.10.20:8000/received | grep -c control_id) -ge 6 ]" || fail "results 5 and 6 should be delivered"
ids=$(on edge2 curl -s http://10.0.10.20:8000/received | grep -o 'LAB-10[0-9]*' | tr '\n' ' ')
echo "The lab API received: $ids"
[ "$ids" = "LAB-1001 LAB-1002 LAB-1003 LAB-1004 LAB-1005 LAB-1006 " ] || fail "expected LAB-1001 to LAB-1006 once each, in order"

step "4. edge1's NATS has caught up again (every stream back to three current replicas)"
# streams <host>: each stream on that host's NATS server with its last sequence number
streams() {
  on "$1" curl -s "http://127.0.0.1:8222/jsz?streams=true" |
    python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(sorted(s['name']+'='+str(s['state']['last_seq']) for a in d.get('account_details',[]) for s in a.get('stream_detail',[]))))"
}
caught_up() { a=$(streams edge1); [ -n "$a" ] && [ "$a" = "$(streams edge2)" ]; }
wait_for 120 caught_up || fail "edge1's NATS did not catch up: edge1 has [$(streams edge1)], edge2 has [$(streams edge2)]"
echo "edge1 holds the same streams as edge2 again: $(streams edge1)"

step "Passed. Clean up with: docker compose down -v"
