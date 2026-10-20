#!/usr/bin/env sh
# Runs every step of sample 11 and checks the result. Needs .env (see README.md).
set -eu
cd "$(dirname "$0")"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
. ./.env
send() { docker compose --progress quiet run --rm -T send --to gateway:7890 "$@"; }
api() { curl -s -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" "http://localhost:8080/api/$1"; }
lab() { curl -s http://localhost:8000/received | grep -o '"control_id": "[^"]*"' | cut -d'"' -f4 | tr '\n' ' '; }
his() { docker compose logs his | grep -o '[A-Z][A-Z] ADT-9[0-9]*' | tr '\n' ' '; }
archive() { docker compose exec -T sftp sh -c 'cat /home/hospital/inbox/*.hl7 2>/dev/null' | tr '\r' '\n' | grep '^MSH' | cut -d'|' -f10 | tr '\n' ' '; }
closed_files() { docker compose exec -T sftp sh -c 'ls /home/hospital/inbox | grep -c "\.hl7$"' || true; }
# A destination's queue (or dead letters) by API: the control IDs in it.
box() { api "routes/adt-feed/messages/$2?destination=$1" | grep -o '"control_id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' '; }
ready() { curl -sf http://localhost:8080/ready >/dev/null; }
wait_until() { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n - 1)); done; return 1; }
is() { [ "$($1)" = "$2" ]; }

step "Starting the gateway, the lab API, the downstream HIS and the archive's SFTP server"
docker compose --progress quiet up -d
wait_until 60 ready || fail "the gateway is not ready; see: docker compose logs gateway"
echo "One route, adt-feed: two sources, three destinations."

step "1. MEDITECH sends four ADT events"
send /messages/adt-a01-inpatient.hl7 /messages/adt-a04-emergency.hl7 /messages/adt-a08-outpatient.hl7 /messages/adt-a03-discharge.hl7
wait_until 20 is his "AA ADT-9001 AA ADT-9002 AA ADT-9003 AA ADT-9004 " || fail "the HIS should get all four, in order: $(his)"
echo "his (every event):                  $(his)"
wait_until 20 is lab "ADT-9001 ADT-9002 " || fail "the lab should get only the inpatient A01 and the emergency A04: $(lab)"
echo "lab (A01/A04/A08 with PV1-2 I or E): $(lab)"
echo "ADT-9003 (an outpatient A08) and ADT-9004 (an A03) are not for the lab."

step "2. The partner clinic posts an ADT event over HTTP"
curl -s -H "X-API-Key: $PARTNER_API_KEY" -H "Content-Type: x-application/hl7-v2+er7" \
  --data-binary @messages/adt-a04-partner.hl7 http://localhost:8443/hl7/adt | tr '\r' '\n' | grep MSA
wait_until 20 is lab "ADT-9001 ADT-9002 ADT-9005 " || fail "the lab should get the partner's emergency A04"
wait_until 30 is closed_files 1 || fail "the fifth event should close the archive's first batch file"
echo "his: $(his)"
echo "lab: $(lab)"
echo "archive, batch file 1 (closed at 5 events): $(archive)"

step "3. The lab API goes down; the HIS and the archive keep getting events"
curl -s -X POST http://localhost:8000/control/down >/dev/null
send /messages/adt-a01-during-outage.hl7
wait_until 20 is his "AA ADT-9001 AA ADT-9002 AA ADT-9003 AA ADT-9004 AA ADT-9005 AA ADT-9006 " || fail "the HIS should get ADT-9006 while the lab is down"
wait_until 15 is "box lab queue" "ADT-9006 " || fail "ADT-9006 should wait in the lab's own queue"
echo "The HIS has ADT-9006; it waits in the lab's queue only. Open http://localhost:8080: lab is retrying."
sleep 5
curl -s -X POST http://localhost:8000/control/up >/dev/null
wait_until 45 is lab "ADT-9001 ADT-9002 ADT-9005 ADT-9006 " || fail "the lab should catch up once it is back"
echo "The lab is back and has caught up: $(lab)"

step "4. A patient the HIS doesn't know: dead letters for the HIS only"
send /messages/adt-a08-unknown-patient.hl7
wait_until 20 is "box his dlq" "ADT-9007 " || fail "ADT-9007 should be in the HIS's dead letters"
wait_until 20 is lab "ADT-9001 ADT-9002 ADT-9005 ADT-9006 ADT-9007 " || fail "the lab should still get ADT-9007"
echo "his dead letters: $(box his dlq)  (the lab and the archive got ADT-9007 as usual)"
wait_until 40 is closed_files 2 || fail "max_wait should close the archive's second batch file"
echo "archive, both batch files: $(archive)"

echo
echo "Done. Two senders, one route, three destinations: filtered, independent, and nothing lost."
