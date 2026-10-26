#!/usr/bin/env sh
# Runs every step of sample 15 and checks the result. Needs .env (see README.md).
set -eu
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep /home/… and /files/… as they are
cd "$(dirname "$0")"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
. ./.env
tool() { docker compose --progress quiet run --rm -T tool "$@"; }
# drop ACCOUNT FOLDER FILE: a file from files/ into an SFTP folder, written under a temporary name and then
# renamed, as SFTP uploads are.
drop() {
  docker compose exec -T sftp sh -c 'f=/home/$1/$2/$3; cat > "$f.tmp" && chown "$1:users" "$f.tmp" && mv "$f.tmp" "$f"' \
    sh "$1" "$2" "$3" < "files/$3"
}
on_sftp() { docker compose exec -T sftp sh -c "$1"; }
has_file() { docker compose exec -T sftp test -f "/home/$1"; }
files_in() { on_sftp "ls -1 /home/$1 2>/dev/null | grep -c '\\.x12\$'" || true; }
count_is() { [ "$(files_in "$1")" = "$2" ]; }
revenue() { docker compose logs revenue | grep "revenue: EFT" | sed 's/^.*| //' || true; }
remits_are() { [ "$(revenue | wc -l | tr -d ' ')" = "$1" ]; }
ask() {
  curl -s -H "X-API-Key: $REGISTRATION_API_KEY" -H "Content-Type: application/edi-x12" --data-binary "@files/$1" \
    -w '\nHTTP %{http_code}\n' http://localhost:8081/eligibility
}
api() { curl -s -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" "http://localhost:8080/api/$1"; }
ready() { curl -sf http://localhost:8080/ready >/dev/null; }
wait_until() { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n - 1)); done; return 1; }

step "Starting the SFTP server, the gateway, a revenue API and the payer's CORE server"
docker compose --progress quiet up -d
wait_until 60 ready || fail "the gateway is not ready; see: docker compose logs gateway"
echo "Three X12 routes: claims-to-clearinghouse, reports-to-billing and eligibility."

step "0. Check the claim files first, as billing would"
tool x12 /files/1-claims.x12 || fail "the claims should be accepted"
if tool x12 /files/2-claim-missing-subscriber.x12; then fail "the claim without a subscriber should be rejected"; fi
echo "(x12 exits 3 when something is rejected)"

step "1. Billing drops two claims (837P), and one without its subscriber"
drop billing outbox 1-claims.x12
drop billing outbox 2-claim-missing-subscriber.x12
wait_until 30 has_file billing/outbox/acks/1-claims.x12.ack.x12 || fail "the gateway should write the answers to outbox/acks"
wait_until 30 has_file billing/outbox/acks/2-claim-missing-subscriber.x12.ack.x12 || fail "the rejected claim should be answered too"
acks=$(on_sftp "cat /home/billing/outbox/acks/1-claims.x12.ack.x12")
[ "$(printf '%s' "$acks" | grep -o 'TA1\*00000010[12]\*[0-9]*\*[0-9]*\*A' | wc -l | tr -d ' ')" = 2 ] || fail "both interchanges should get a TA1 (A)"
[ "$(printf '%s' "$acks" | grep -o 'AK9\*A\*1\*1\*1' | wc -l | tr -d ' ')" = 2 ] || fail "both should get a 999 that accepts them"
echo "outbox/acks/1-claims.x12.ack.x12: a TA1 and an accepting 999 for each interchange"
rejected=$(on_sftp "cat /home/billing/outbox/acks/2-claim-missing-subscriber.x12.ack.x12")
printf '%s' "$rejected" | grep -q 'AK9\*R\*1\*1\*0' || fail "the claim without a subscriber should get a rejecting 999"
printf '%s' "$rejected" | grep -q 'IK3\*NM1\*[0-9]*\*2010BA\*3' || fail "the 999 should say the subscriber (2010BA NM1) is missing"
echo "outbox/acks/2-claim-missing-subscriber.x12.ack.x12: IK3*NM1…2010BA*3 (required segment missing), AK9*R"
wait_until 30 has_file billing/outbox/errors/2-claim-missing-subscriber.x12.txt || fail "the rejected interchange should go to outbox/errors"
on_sftp "cat /home/billing/outbox/errors/2-claim-missing-subscriber.x12.txt"

step "2. The clearinghouse gets each accepted claim in the gateway's envelope"
wait_until 30 count_is northside/inbound 2 || fail "two claim files should be in the clearinghouse's inbound folder"
on_sftp "ls -1 /home/northside/inbound"
sent=$(on_sftp "cat /home/northside/inbound/claims_NSBILLING_000000101.x12")
printf '%s' "$sent" | grep -q '^ISA\*00\*          \*00\*          \*ZZ\*NORTHSIDE      \*ZZ\*ACMECLEAR      \*' ||
  fail "the claim should be sent as NORTHSIDE, not as the billing system"
printf '%s' "$sent" | grep -q 'CLM\*PAT1001\*150' || fail "the claim should be as billing sent it"
echo "ISA: $(printf '%s' "$sent" | head -1 | cut -c1-106)"
echo "The billing system's own ISA/GS (NSBILLING) became the hospital's (NORTHSIDE), with the gateway's control numbers."

step "3. The clearinghouse drops a remittance (835) and a claim acknowledgment (277CA)"
drop northside reports 3-remittance-835.x12
drop northside reports 4-claim-acknowledgment-277ca.x12
wait_until 30 remits_are 2 || fail "the revenue API should get both claims of the remittance"
revenue
[ "$(revenue | grep -c 'PAT1001 billed 150 paid 120 patient owes 30')" = 1 ] || fail "PAT1001: paid 120, patient owes 30"
wait_until 30 count_is billing/inbox 1 || fail "the 277CA should go to billing's inbox"
echo "billing/inbox: $(on_sftp 'ls -1 /home/billing/inbox')"
curl -s http://localhost:8080/metrics -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" | grep '^hl7edge_x12_acks_total' || true

step "4. Registration asks the payer about two patients (270), in real time over CAQH CORE"
out=$(ask 5-eligibility-270.x12)
printf '%s\n' "$out" | grep -q '^HTTP 200$' || fail "the eligibility request should get 200: $out"
printf '%s\n' "$out" | grep -q '^EB\*1\*IND\*30\*\*GOLD PLAN~' || fail "Ana Rivera should be covered (EB*1)"
printf '%s\n' "$out" | grep -E '^(ST|NM1\*IL|EB|MSG)\*'
out=$(ask 6-eligibility-270-not-covered.x12)
printf '%s\n' "$out" | grep -q '^AAA\*Y\*\*75\*C~' || fail "the second patient should be 'subscriber not found' (AAA 75)"
printf '%s\n' "$out" | grep -E '^(NM1\*IL|AAA)\*'
docker compose logs payer | grep "payer: Success" | sed 's/^.*| //'
status=$(curl -s -o /dev/null -w '%{http_code}' --data-binary @files/5-eligibility-270.x12 http://localhost:8081/eligibility || true)
[ "$status" = 401 ] || fail "a request without the API key should get 401, got $status"
echo "Without X-API-Key: HTTP 401"
curl -s http://localhost:8080/metrics | grep '^hl7edge_core_requests_total' || fail "the CORE requests should be counted"

step "5. See the remittance as JSON, as the revenue API got it"
tool x12 --json /files/3-remittance-835.x12 | sed -n '/^{/,$p' | head -40
echo "…"

echo
echo "Done. Claims checked and acknowledged for billing, sent on in the hospital's envelope; the remittance as JSON"
echo "for the revenue API and the 277CA for billing; eligibility from the payer in real time. Console: http://localhost:8080."
