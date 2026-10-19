#!/usr/bin/env sh
# Runs every step of sample 03 and checks the result. Needs .env (see README.md).
set -eu
cd "$(dirname "$0")"
OUT=$(mktemp ./.output.XXXXXX); trap 'rm -f "$OUT"' EXIT
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
send() { docker compose --progress quiet run --rm -T send "$@"; }
sb() { docker compose --progress quiet run --rm -T sb "$@"; }
filed() { docker compose logs meditech | grep -c "$1" || true; }
emulator_up() { docker compose logs servicebus 2>&1 | grep -q "Successfully Up"; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"

step "Starting the gateway, a stand-in MEDITECH and the Service Bus emulator"
docker compose --progress quiet --profile tools build sb
docker compose --progress quiet up -d
echo "Waiting for the emulator (a minute or two)..."
for i in $(seq 1 100); do emulator_up && break; sleep 3; done
emulator_up || fail "the emulator did not start; see: docker compose logs servicebus"
for i in $(seq 1 90); do docker compose logs gateway | grep -q "connected to sb://" && break; sleep 2; done
docker compose logs gateway | grep -q "connected to sb://" || fail "the gateway did not connect to Service Bus"
echo "The gateway is connected to Service Bus."

step "1. MEDITECH sends lab results; the gateway publishes them to the topic lab-results"
send --to gateway:7890 /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7
sleep 2
sb receive lab-results analytics | tee "$OUT"
grep -q "analytics: 2 message" "$OUT" || fail "the analytics subscription should have 2 results"
sb receive lab-results archive | tee "$OUT"
grep -q "archive: 2 message" "$OUT" || fail "the archive subscription should have its own copy of both"

step "2. A cloud application puts orders on the queue orders-inbound; the gateway sends them to MEDITECH"
sb send orders-inbound /messages/orm-o01-1.hl7 /messages/orm-o01-2.hl7 /messages/orm-o01-unknown-patient.hl7
for i in $(seq 1 20); do [ "$(filed 'ORD-60[09][129]')" -ge 3 ] && break; sleep 1; done
docker compose logs meditech | grep "ORD-60"
[ "$(filed 'AA ORD-600[12]')" = 2 ] || fail "MEDITECH should have filed ORD-6001 and ORD-6002"
echo "ORD-6099 was rejected by MEDITECH (AR): it is in the gateway's dead letters."

step "3. MEDITECH goes down; orders wait in the gateway, not in Service Bus"
docker compose --progress quiet stop meditech
sb send orders-inbound /messages/orm-o01-3.hl7
echo "Open http://localhost:8080: orders-from-service-bus is retrying with 1 queued. Waiting 10 s..."
sleep 10
docker compose --progress quiet start meditech
for i in $(seq 1 45); do [ "$(filed 'AA ORD-6003')" = 1 ] && break; sleep 1; done
[ "$(filed 'AA ORD-6003')" = 1 ] || fail "ORD-6003 should be filed once MEDITECH is back"
echo "MEDITECH is back; ORD-6003 filed after ${i}s."

step "4. Service Bus is unreachable; results wait in the gateway"
docker compose --progress quiet stop servicebus
send --to gateway:7890 /messages/oru-r01-3.hl7
echo "MEDITECH got AA. Open http://localhost:8080: results-to-service-bus is retrying with 1 queued."
sleep 10
docker compose --progress quiet start servicebus
echo "Waiting for the emulator to come back..."
for i in $(seq 1 100); do [ "$(docker compose logs servicebus 2>&1 | grep -c 'Successfully Up')" -ge 2 ] && break; sleep 3; done
for i in $(seq 1 60); do sb receive lab-results analytics > "$OUT"; grep -q RES-5003 "$OUT" && break; sleep 5; done
grep -q RES-5003 "$OUT" || fail "RES-5003 should be published once Service Bus is back"
cat "$OUT"

step "Done. Clean up with: docker compose down -v"
