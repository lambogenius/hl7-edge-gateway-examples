#!/usr/bin/env sh
# Runs every step of sample 04 and checks the result. Needs .env and secrets/salesforce.key (see README.md).
set -eu
cd "$(dirname "$0")"
OUT=$(mktemp ./.response.XXXXXX); trap 'rm -f "$OUT"' EXIT
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and fill it in"
. ./.env
[ -f secrets/salesforce.key ] || fail "put the Salesforce private key in secrets/salesforce.key"
# Windows curl (Schannel) cannot check revocation for a test CA that publishes no revocation list.
TLS="--cacert certs/ca.crt"; curl --version | grep -q Schannel && TLS="$TLS --ssl-no-revoke"
# order [curl options...]: POST orm-o01-1.hl7 to the Entra-protected route; prints the HTTP status
order() { curl -s $TLS -H "Content-Type: x-application/hl7-v2+er7" "$@" -o "$OUT" -w '%{http_code}' https://localhost:8443/hl7/orders; }
# route_field <route> <field>: a value from the admin API's overview
route_field() {
  curl -s -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" http://localhost:8080/api/overview |
    python3 -c "import json,sys; r=[r for n in json.load(sys.stdin)['nodes'] for r in n['routes'] if r['name']==sys.argv[1]][0]; v=r.get(sys.argv[2], r['counters'].get(sys.argv[2])); print(v if v is not None else '')" "$1" "$2"
}

step "Starting: test certificate, the gateway, and a stand-in MEDITECH"
docker compose --progress quiet up -d
for i in $(seq 1 30); do curl -sf http://localhost:8080/ready >/dev/null && break; sleep 1; done
curl -sf http://localhost:8080/ready >/dev/null || fail "the gateway is not ready; see: docker compose logs gateway"

step "1. The care app gets an Entra ID access token (client credentials)"
TOKEN=$(./get-token.sh)
[ -n "$TOKEN" ] || fail "no token: check ENTRA_TENANT_ID, CARE_APP_CLIENT_ID, CARE_APP_CLIENT_SECRET and GATEWAY_API_APP_ID"
printf '%s' "$TOKEN" | cut -d. -f2 | python3 -c "import sys,json,base64; p=sys.stdin.read().strip(); p+='='*(-len(p)%4); d=json.loads(base64.urlsafe_b64decode(p)); print('  issuer:  ', d['iss']); print('  audience:', d['aud']); print('  roles:   ', d.get('roles'))"

step "2. ... and posts an order with it"
[ "$(order -H "Authorization: Bearer $TOKEN" --data-binary @messages/orm-o01-1.hl7)" = 200 ] || { cat "$OUT"; fail "the order should be accepted"; }
cat "$OUT"; echo
docker compose logs meditech | grep CARE-8001

step "3. Requests without a valid token are refused"
code=$(order --data-binary @messages/orm-o01-2.hl7); echo "no token:       HTTP $code $(cat "$OUT")"; [ "$code" = 401 ] || fail "expected 401"
code=$(order -H "Authorization: Bearer ${TOKEN%?????}AAAAA" --data-binary @messages/orm-o01-2.hl7)
echo "tampered token: HTTP $code $(cat "$OUT")"; [ "$code" = 401 ] || fail "expected 401"

step "4. MEDITECH sends lab results; the gateway posts them to Salesforce"
docker compose --progress quiet run --rm -T send --to gateway:7890 /messages/oru-r01-1.hl7 /messages/oru-r01-2.hl7
for i in $(seq 1 30); do [ "$(route_field results-to-salesforce delivered)" -ge 2 ] && break; sleep 2; done
if [ "$(route_field results-to-salesforce delivered)" -lt 2 ]; then
  echo "Not delivered yet. The gateway's last error: $(route_field results-to-salesforce last_error)"
  fail "results did not reach Salesforce; see Troubleshooting in README.md (they stay queued and are retried)"
fi
echo "Delivered. In Salesforce, open Files: you will find 'HL7 SFR-7001' and 'HL7 SFR-7002'."

step "Done. Clean up with: docker compose down -v"
