#!/usr/bin/env sh
# Runs every step of sample 13 and checks the result. Needs .env (see README.md).
set -eu
cd "$(dirname "$0")"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
. ./.env
table=transforms/tables/patient-class.csv
cp "$table" "$table.orig"
trap 'mv -f "$table.orig" "$table"' EXIT
send() { docker compose --progress quiet run --rm -T send --to gateway:7890 "$@"; }
tool() { docker compose --progress quiet run --rm -T tool "$@"; }
api() { curl -s -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" "http://localhost:8080/api/$1"; }
lis() { docker compose logs --no-log-prefix lis; }
received() { curl -s http://localhost:8000/received; }
# Control IDs the LIS acknowledged, and what the portal and the registry hold.
lis_ids() { lis | grep -o 'lis: AA [A-Z0-9-]*' | cut -d' ' -f3 | tr '\n' ' '; }
portal_count() { received | grep -c '"system": "patient-api"' || true; }
research_count() { received | grep -c '"system": "research"' || true; }
dead_letters() { api "routes/adt-out/messages/dlq?destination=lis" | grep -o '"control_id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' '; }
ready() { curl -sf http://localhost:8080/ready >/dev/null; }
wait_until() { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n - 1)); done; return 1; }
is() { [ "$($1)" = "$2" ]; }

step "Starting the gateway, the LIS, the patient portal's API and the research registry"
docker compose --progress quiet up -d
wait_until 60 ready || fail "the gateway is not ready; see: docker compose logs gateway"
echo "One route, adt-out: three destinations, each with its own transform."

step "1. MEDITECH sends an inpatient admission and an emergency registration"
send /messages/adt-a01-inpatient.hl7 /messages/adt-a04-emergency.hl7 | grep 'MSA|AA|' >/dev/null || fail "both should be acknowledged with AA"
wait_until 20 is lis_ids "ADT-1301 ADT-1302 " || fail "the LIS should get both: $(lis_ids)"
wait_until 20 is portal_count 2 || fail "the portal API should get both"
wait_until 20 is research_count 2 || fail "the research registry should get both"
lis | grep -q 'PV1|1|INPT|' || fail "the LIS should get its own patient class, INPT"
lis | grep -q 'ZLB|ED|STAT' || fail "the LIS should get the ED flag for the emergency registration"
lis | grep -q '^lis:   NK1' && fail "the LIS shouldn't get next of kin"
echo "LIS (HL7, its codes):"
lis | grep -A6 'lis: AA ADT-1302' | sed 's/^lis: */  /'
received | grep -q '"content_type": "application/json"' || fail "the portal should get JSON, as application/json"
received | grep -q '"class": "inpatient"' || fail "the portal's JSON should have the visit class"
received | grep -q '"allergies": \[' || fail "the portal's JSON should list allergies"
echo "Patient portal API (JSON): $(received | grep -o '"event": "[a-z]*"' | tr '\n' ' ')"
research_pid=$(received | grep -o '"PID|[^"]*"' | head -1)
case $research_pid in *200301* | *OKAFOR*) fail "the research registry should get no MRN or name: $research_pid" ;; esac
echo "Research registry (de-identified): $research_pid"

step "2. A patient class the LIS doesn't have: dead letters for the LIS only"
send /messages/adt-a08-boarder.hl7 | grep 'MSA|AA|' >/dev/null || fail "ADT-1303 should be acknowledged: it is stored for every destination"
wait_until 20 is dead_letters "ADT-1303 " || fail "ADT-1303 should be in the LIS's dead letters"
wait_until 20 is portal_count 3 || fail "the portal should still get ADT-1303"
wait_until 20 is research_count 3 || fail "the research registry should still get ADT-1303"
reason=$(api "routes/adt-out/messages/dlq?destination=lis" | sed -n 's/.*"reason":"\(.*\)","dead_lettered_ms.*/\1/p' | sed 's/\\"/"/g')
echo "LIS dead letter: $reason"
echo "$reason" | grep -q 'step 4 (map PV1-2)' || fail "the reason should name the failing step"
seq=$(api "routes/adt-out/messages/dlq?destination=lis" | grep -o '"seq":[0-9]*' | head -1 | cut -d: -f2)
api "routes/adt-out/messages/dlq/$seq?destination=lis&transformed=true" | grep -q '"transform_error"' || fail "the as-sent view should say why"
echo "The dead letter is the event as MEDITECH sent it; the console shows it as received, and why it can't be sent."

step "3. Add the code to the LIS's table, restart, requeue"
printf 'B,BOARDER\n' >> "$table"
tool check -c /sample/gateway.toml | grep -q '3 transform' || fail "check should load the three transforms"
docker compose --progress quiet restart gateway
wait_until 60 ready || fail "the gateway is not ready after the restart"
curl -s -X POST -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" "http://localhost:8080/api/routes/adt-out/messages/dlq/$seq/requeue?destination=lis" >/dev/null
wait_until 20 is lis_ids "ADT-1301 ADT-1302 ADT-1303 " || fail "the LIS should get ADT-1303 now: $(lis_ids)"
lis | grep -q 'PV1|1|BOARDER|' || fail "ADT-1303 should reach the LIS with the new code"
echo "The LIS has ADT-1303, transformed with the new table entry: PV1|1|BOARDER"

step "4. See what a transform does, without sending anything"
tool transform -c /sample/gateway.toml --destination lis --diff /messages/adt-a04-emergency.hl7

echo
echo "Done. One feed, three shapes; a transform that can't map a code holds that event for that system only."
