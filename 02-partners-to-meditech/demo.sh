#!/usr/bin/env sh
# Runs every step of sample 02 and checks the result. Needs .env (see README.md).
set -eu
cd "$(dirname "$0")"
OUT=$(mktemp ./.response.XXXXXX); trap 'rm -f "$OUT"' EXIT
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
. ./.env
# Windows curl (Schannel) cannot check revocation for a test CA that publishes no revocation list.
TLS="--cacert certs/ca.crt"; curl --version | grep -q Schannel && TLS="$TLS --ssl-no-revoke"

# rest <api key> <file>: POST a raw HL7 message; prints the JSON ACK and the HTTP status
rest() {
  curl -s $TLS -H "X-API-Key: $1" -H "Content-Type: x-application/hl7-v2+er7" \
    --data-binary "@$2" -o "$OUT" -w '%{http_code}' https://localhost:8443/hl7/results
}
# soap <file>: POST a SOAP envelope as the clinic; prints the HTTP status
soap() {
  curl -s $TLS -u "lakeside-clinic:$CLINIC_SOAP_PASSWORD" -H 'Content-Type: text/xml; charset=utf-8' \
    -H 'SOAPAction: "urn:lakeside-clinic:hl7/SubmitHL7"' --data-binary "@$1" -o "$OUT" -w '%{http_code}' https://localhost:8443/Hl7Service
}
filed() { docker compose logs meditech | grep -c "$1" || true; }

step "Starting: test certificates, the gateway, and a stand-in MEDITECH"
docker compose --progress quiet up -d
for i in $(seq 1 30); do curl -sf http://localhost:8080/ready >/dev/null && break; sleep 1; done
curl -sf http://localhost:8080/ready >/dev/null || fail "the gateway is not ready; see: docker compose logs gateway"

step "1. Two reference labs post results over HTTPS, each with its own API key"
[ "$(rest "$NORTHSIDE_LAB_API_KEY" messages/oru-r01-ref-1.hl7)" = 200 ] || fail "Northside's result should be accepted"; cat "$OUT"; echo
[ "$(rest "$VALLEY_PATHOLOGY_API_KEY" messages/oru-r01-ref-2.hl7)" = 200 ] || fail "Valley's result should be accepted"; cat "$OUT"; echo
echo "A wrong key is refused:"
[ "$(rest wrong-key messages/oru-r01-ref-2.hl7)" = 401 ] || fail "a wrong API key should get 401"; cat "$OUT"; echo
sleep 2
[ "$(filed 'AA REF-300[12]')" = 2 ] || fail "MEDITECH should have filed REF-3001 and REF-3002"
docker compose logs meditech | grep REF-300

step "2. The clinic registers patients over SOAP (pass-through: MEDITECH's ACK comes back)"
[ "$(soap messages/soap-adt-a04.xml)" = 200 ] || fail "the SOAP call should succeed"
grep -o 'MSA|AA|CLN-4001|filed' "$OUT" || fail "the SOAP response should carry MEDITECH's AA"
[ "$(soap messages/soap-adt-a04-unknown-patient.xml)" = 200 ] || fail "the SOAP call should succeed"
grep -o 'MSA|AR|CLN-4099|patient not found: 555002' "$OUT" || fail "the SOAP response should carry MEDITECH's AR"

step "3. MEDITECH goes down"
docker compose --progress quiet stop meditech
[ "$(rest "$NORTHSIDE_LAB_API_KEY" messages/oru-r01-ref-3.hl7)" = 200 ] || fail "results should still be accepted (stored)"
[ "$(rest "$NORTHSIDE_LAB_API_KEY" messages/oru-r01-ref-4.hl7)" = 200 ] || fail "results should still be accepted (stored)"
echo "Results REF-3003 and REF-3004 are stored and acknowledged. A SOAP registration cannot be:"
[ "$(soap messages/soap-adt-a04.xml)" = 200 ] || fail "the SOAP call should still get a response"
grep -o 'MSA|AE|CLN-4001|[^&]*' "$OUT" || fail "pass-through SOAP should get AE while MEDITECH is down"
echo "Open http://localhost:8080: reference-lab-results is retrying with 2 queued. Waiting 10 s..."
sleep 10

step "4. MEDITECH comes back"
docker compose --progress quiet start meditech
for i in $(seq 1 45); do [ "$(filed 'AA REF-300[34]')" = 2 ] && break; sleep 1; done
[ "$(filed 'AA REF-300[34]')" = 2 ] || fail "the queued results were not delivered"
echo "Delivered after ${i}s, in order:"; docker compose logs meditech | grep 'REF-300[34]'

step "5. A result for a patient MEDITECH does not know"
[ "$(rest "$NORTHSIDE_LAB_API_KEY" messages/oru-r01-ref-unknown-patient.hl7)" = 200 ] || fail "the result should be stored"
sleep 3
docker compose logs meditech | grep REF-3099
echo "MEDITECH answered AR, so REF-3099 is in dead letters: open reference-lab-results -> Dead letters."

step "Done. Clean up with: docker compose down -v"
