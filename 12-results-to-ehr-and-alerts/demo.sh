#!/usr/bin/env sh
# Runs every step of sample 12 and checks the result. Needs .env (see README.md).
set -eu
cd "$(dirname "$0")"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
. ./.env
# Sends as the LIS and prints the ACK codes it gets back, e.g. "AA RES-1201".
send() { docker compose --progress quiet run --rm -T send --to gateway:7890 "$@" 2>&1 | sed -n 's/.*MSA|\([A-Z][A-Z]\)|\([^|]*\).*/\1 \2/p'; }
filter() { docker compose --progress quiet run --rm -T --entrypoint hl7-edge-gateway send filter "$@" || true; }
api() { curl -s -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" "http://localhost:8080/api/$1"; }
ehr() { docker compose logs ehr | grep -o 'A[AR] RES-12[0-9]*' | tr '\n' ' '; }
alerts() { curl -s "http://localhost:$1/received" | grep -o '"control_id": "[^"]*"' | cut -d'"' -f4 | tr '\n' ' '; }
pager() { alerts 8001; }
infection_control() { alerts 8002; }
queued() { api "routes/results/messages/queue?destination=$1" | grep -o '"control_id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' '; }
ready() { curl -sf http://localhost:8080/ready >/dev/null; }
wait_until() { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n - 1)); done; return 1; }
is() { [ "$($1)" = "$2" ]; }
expect() { [ "$1" = "$2" ] || fail "$3: got \"$1\""; echo "LIS got: $1"; }

step "Starting the gateway, the EHR, the pager and infection control"
docker compose --progress quiet up -d
wait_until 60 ready || fail "the gateway is not ready; see: docker compose logs gateway"
echo "One route, results: pass-through to the EHR; copies to the pager and infection control."

step "1. The LIS sends four results; each ACK is the EHR's own"
expect "$(send /messages/oru-normal.hl7 /messages/oru-critical-potassium.hl7 /messages/oru-positive-culture.hl7 \
  /messages/oru-negative-culture-abnormal-urine.hl7 | tr '\n' ' ')" "AA RES-1201 AA RES-1202 AA RES-1203 AA RES-1204 " \
  "the EHR should file all four"
wait_until 20 is pager "RES-1202 " || fail "the pager should get the critical potassium only: $(pager)"
wait_until 20 is infection_control "RES-1203 " || fail "infection control should get the positive blood culture only: $(infection_control)"
docker compose logs --no-log-prefix pager infection-control | grep RES-
echo "RES-1201 is normal. RES-1204 has a negative blood culture and an abnormal urinalysis: not a positive culture."

step "2. Why not RES-1204: the same conditions without a group, then with one"
filter -f @/filters/positive-culture-flat.toml /messages/oru-negative-culture-abnormal-urine.hl7
filter -f @/filters/positive-culture-group.toml /messages/oru-negative-culture-abnormal-urine.hl7

step "3. A critical result for a patient the EHR doesn't know"
expect "$(send /messages/oru-critical-unknown-patient.hl7)" "AR RES-1205" "the EHR should reject RES-1205"
sleep 3
is pager "RES-1202 " || fail "RES-1205 should not be copied: the EHR didn't accept it"
echo "The LIS has the EHR's AR to act on; nothing was copied, so nobody is paged for a result that isn't filed."

step "4. The EHR is down: the LIS gets AE and resends"
docker compose --progress quiet stop ehr
expect "$(send /messages/oru-critical-glucose.hl7)" "AE RES-1206" "with the EHR down, the LIS should get AE"
is pager "RES-1202 " || fail "RES-1206 should not be copied while the EHR hasn't filed it"
docker compose --progress quiet start ehr
sleep 2
expect "$(send /messages/oru-critical-glucose.hl7)" "AA RES-1206" "the resend should be filed"
wait_until 20 is pager "RES-1202 RES-1206 " || fail "the pager should get RES-1206 once the EHR filed it: $(pager)"
echo "pager: $(pager)"

step "5. The pager is down: the LIS isn't held up, and the page waits in the pager's queue"
curl -s -X POST http://localhost:8001/control/down >/dev/null
expect "$(send /messages/oru-critical-during-pager-outage.hl7)" "AA RES-1207" "the EHR should file RES-1207 while the pager is down"
wait_until 20 is infection_control "RES-1203 RES-1207 " || fail "infection control should get the positive urine culture: $(infection_control)"
wait_until 15 is "queued pager" "RES-1207 " || fail "RES-1207 should wait in the pager's queue"
echo "Infection control has RES-1207; it waits in the pager's queue. Open http://localhost:8080: pager is retrying."
sleep 5
curl -s -X POST http://localhost:8001/control/up >/dev/null
wait_until 45 is pager "RES-1202 RES-1206 RES-1207 " || fail "the pager should catch up once it is back: $(pager)"
echo "The pager is back and has caught up: $(pager)"

echo
echo "Done. The LIS hears from the EHR itself; the pager and infection control get what the EHR filed, per order."
