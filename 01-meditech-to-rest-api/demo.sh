#!/usr/bin/env sh
# Runs every step of sample 01 and checks the result. Needs .env (see README.md).
set -eu
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
cd "$(dirname "$0")"
send() { docker compose --progress quiet run --rm -T send "$@"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
received() { curl -s http://localhost:8000/received | grep -c control_id || true; }

[ -f .env ] || fail "copy .env.example to .env and put your license in it"
step "Starting the gateway and the stand-in lab API"
docker compose --progress quiet up -d
for i in $(seq 1 30); do curl -sf http://localhost:8080/ready >/dev/null && break; sleep 1; done
curl -sf http://localhost:8080/ready >/dev/null || fail "the gateway is not ready; see: docker compose logs gateway"

step "1. Three lab results (store and forward) and an admission (pass-through)"
send --to gateway:7890 /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7 /messages/oru-r01-3.hl7
send --to gateway:7891 /messages/adt-a01.hl7
for i in $(seq 1 10); do [ "$(received)" -ge 4 ] && break; sleep 1; done
[ "$(received)" -ge 4 ] || fail "the lab API should have 4 messages"
echo "The lab API has received $(received) messages."

step "2. The lab API goes down"
curl -s -X POST http://localhost:8000/control/down; echo
send --to gateway:7890 /messages/oru-r01-4.hl7 /messages/oru-r01-5.hl7 | tee "$OUT"
grep -q 'MSA|AA|LAB-1005' "$OUT" || fail "results should still be acknowledged (AA) while the API is down"
echo "Results are acknowledged and queued. Now an admission (pass-through) while the API is down:"
send --to gateway:7891 /messages/adt-a08.hl7 | tee "$OUT" || true
grep -q 'MSA|AE|ADT-2002' "$OUT" || fail "a pass-through admission should get AE while the API is down"
echo "Open http://localhost:8080: lab-results is retrying with 2 queued. Waiting 10 s..."
sleep 10

step "3. The lab API comes back"
curl -s -X POST http://localhost:8000/control/up; echo
for i in $(seq 1 45); do [ "$(received)" -ge 6 ] && break; sleep 1; done
[ "$(received)" -ge 6 ] || fail "the queued results were not delivered"
echo "Queued results delivered after ${i}s, in order:"
curl -s http://localhost:8000/received | grep control_id | tail -2

step "4. A result without a patient ID"
send --to gateway:7890 /messages/oru-r01-no-patient-id.hl7
sleep 3
docker compose logs lab-api | grep LAB-1099
echo "LAB-1099 is in dead letters: open lab-results -> Dead letters in the console."

step "Done. Clean up with: docker compose down -v"
