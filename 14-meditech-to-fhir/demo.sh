#!/usr/bin/env sh
# Runs every step of sample 14 and checks the result. Needs .env (see README.md).
set -eu
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep /messages/… as it is
cd "$(dirname "$0")"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
. ./.env
fhir=http://localhost:8090/fhir
mrn="identifier=https://general-hospital.example/id/GENERAL_HOSPITAL|200301"
send() { docker compose --progress quiet run --rm -T send --to gateway:7890 "$@"; }
tool() { docker compose --progress quiet run --rm -T tool "$@"; }
api() { curl -s -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" "http://localhost:8080/api/$1"; }
get() { curl -s "$fhir/$1"; }
# total TYPE [QUERY]: how many TYPE resources the FHIR server has (that match QUERY).
total() { get "$1?_summary=count${2:+&$2}" | grep -o '"total": [0-9]*' | cut -d' ' -f2; }
# first FIELD TYPE QUERY: the first "FIELD": value in the first match.
first() { get "$2?$3" | grep -o "\"$1\": [^,}]*" | head -1 | cut -d' ' -f2- | tr -d '"'; }
delivered() { api overview | grep -o '"delivered":[0-9]*' | head -1 | cut -d: -f2; }
ready() { curl -sf http://localhost:8080/ready >/dev/null && curl -sf "$fhir/metadata" >/dev/null; }
wait_until() { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n - 1)); done; return 1; }
is() { [ "$($1)" = "$2" ]; }

step "Starting the gateway and the FHIR server (HAPI FHIR takes about a minute the first time)"
docker compose --progress quiet up -d
wait_until 180 ready || fail "not ready; see: docker compose logs gateway fhir-server"
echo "One route, meditech-to-fhir: MLLP in, a FHIR transaction out for each message."

step "1. MEDITECH admits a patient (ADT^A01)"
send /messages/1-adt-a01-admit.hl7 | grep 'MSA|AA|' >/dev/null || fail "the admission should be acknowledged with AA"
wait_until 30 is delivered 1 || fail "the gateway should deliver the admission"
[ "$(total Patient "$mrn")" = 1 ] || fail "the FHIR server should have the patient"
[ "$(first status Encounter "identifier=https://general-hospital.example/id/GENERAL_HOSPITAL|V5001")" = in-progress ] || fail "the visit should be in progress"
echo "Patient $(first family Patient "$mrn"), $(first gender Patient "$mrn"), born $(first birthDate Patient "$mrn")"
[ "$(total Encounter "identifier=https://general-hospital.example/id/GENERAL_HOSPITAL|V5001&class=IMP")" = 1 ] || fail "the visit should be inpatient (IMP)"
echo "Encounter V5001: in-progress, inpatient (IMP), admitted $(first start Encounter "identifier=https://general-hospital.example/id/GENERAL_HOSPITAL|V5001")"
echo "Also: RelatedPerson $(total RelatedPerson), AllergyIntolerance $(total AllergyIntolerance), Condition $(total Condition), Practitioner $(total Practitioner)"

step "2. The doctor orders a metabolic panel (ORM^O01), and the lab sends the results (ORU^R01)"
send /messages/2-orm-o01-order.hl7 /messages/3-oru-r01-results.hl7 | grep -c 'MSA|AA|' | grep -q 2 || fail "both should be acknowledged with AA"
wait_until 30 is delivered 3 || fail "the gateway should deliver both"
[ "$(total Patient)" = 1 ] || fail "results and orders shouldn't make a second patient"
[ "$(total Observation)" = 3 ] || fail "three results should be three Observations"
[ "$(first status DiagnosticReport "identifier=https://general-hospital.example/id/LAB|LAB-55501")" = final ] || fail "the report should be final"
glucose=$(first value Observation "code=http://loinc.org|2345-7")
[ "$glucose" = 182 ] || fail "glucose should be 182, got $glucose"
echo "ServiceRequest ORD-1001: $(first status ServiceRequest "identifier=https://general-hospital.example/id/MEDITECH|ORD-1001"), DiagnosticReport LAB-55501: final"
echo "Observations: $(total Observation); glucose $glucose mg/dL ($(first status Observation "code=http://loinc.org|2345-7"))"

step "3. The lab corrects the glucose (ORU^R01 again, OBX-11 = C)"
send /messages/4-oru-r01-corrected.hl7 | grep 'MSA|AA|' >/dev/null || fail "the correction should be acknowledged with AA"
wait_until 30 is delivered 4 || fail "the gateway should deliver the correction"
[ "$(total Observation)" = 3 ] || fail "the correction should replace the results, not add three more"
glucose=$(first value Observation "code=http://loinc.org|2345-7")
[ "$glucose" = 128 ] || fail "glucose should now be 128, got $glucose"
[ "$(first status Observation "code=http://loinc.org|2345-7")" = corrected ] || fail "the glucose should be corrected"
echo "Still $(total Observation) Observations; glucose $glucose mg/dL (corrected); DiagnosticReport $(first status DiagnosticReport "identifier=https://general-hospital.example/id/LAB|LAB-55501")"

step "4. A flu shot (VXU^V04)"
send /messages/5-vxu-v04-flu-shot.hl7 | grep 'MSA|AA|' >/dev/null || fail "the immunization should be acknowledged with AA"
wait_until 30 is delivered 5 || fail "the gateway should deliver the immunization"
[ "$(first status Immunization "patient.identifier=https://general-hospital.example/id/GENERAL_HOSPITAL|200301")" = completed ] || fail "the flu shot should be completed"
echo "Immunization: completed, lot $(first lotNumber Immunization "_sort=-_lastUpdated")"

step "5. MEDITECH discharges the patient (ADT^A03)"
send /messages/6-adt-a03-discharge.hl7 | grep 'MSA|AA|' >/dev/null || fail "the discharge should be acknowledged with AA"
wait_until 30 is delivered 6 || fail "the gateway should deliver the discharge"
[ "$(first status Encounter "identifier=https://general-hospital.example/id/GENERAL_HOSPITAL|V5001")" = finished ] || fail "the visit should be finished"
[ "$(total Encounter)" = 1 ] || fail "the discharge should update the visit, not add one"
echo "Encounter V5001: finished, ended $(first end Encounter "identifier=https://general-hospital.example/id/GENERAL_HOSPITAL|V5001")"

step "6. A recurring visit with MEDITECH's own patient class, RCR (ADT^A04)"
send /messages/7-adt-a04-recurring.hl7 | grep 'MSA|AA|' >/dev/null || fail "the registration should be acknowledged with AA"
wait_until 30 is delivered 7 || fail "the gateway should deliver the registration"
[ "$(total Encounter "identifier=https://general-hospital.example/id/GENERAL_HOSPITAL|V5107&class=AMB")" = 1 ] || fail "RCR should become the AMB class (fhir/tables.toml)"
echo "Encounter V5107: ambulatory (AMB), from MEDITECH's RCR through fhir/tables.toml"
api overview | grep -q '"transform":"inline: fhir: templates fhir, transaction"' || fail "the console should show the FHIR transform"
curl -s http://localhost:8080/metrics | grep 'hl7edge_fhir_entries_total.*resource="Observation"'

step "7. See the Bundle a message makes, without sending it"
tool transform -c /sample/gateway.toml --destination fhir /messages/5-vxu-v04-flu-shot.hl7 | head -40
echo "…"

echo
echo "Done. Seven MEDITECH messages, one patient in FHIR: a visit admitted and discharged, results corrected in place,"
echo "a flu shot, and a recurring visit with MEDITECH's own code. Browse them at http://localhost:8090."
