#!/usr/bin/env sh
# Runs every step of sample 10 and checks the result. Needs .env (see README.md).
set -eu
cd "$(dirname "$0")"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
[ -f .env ] || fail "copy .env.example to .env and put your license in it"
. ./.env
send() { docker compose --progress quiet run --rm -T send --to gateway:7890 "$@"; }
# The lab drops a file in its outbox: written under a temporary name, then renamed, as SFTP uploads are.
lab_drop() {
  docker compose exec -T sftp sh -c 'f=/home/hospital/outbox/$1; cat > "$f.tmp" && chown 1001:100 "$f.tmp" && mv "$f.tmp" "$f"' sh "$1" < "messages/$1"
}
lab_ls() { docker compose exec -T sftp sh -c "cd /home/hospital/$1 && ls -1 | grep -v '^processed$' | grep -v '^errors$'" || true; }
lab_cat() { docker compose exec -T sftp sh -c "cat /home/hospital/$1" | tr -d '\r'; }
meditech() { docker compose logs meditech | grep "meditech results:" | sed 's/^.*| //' || true; }
filed() { meditech | grep -c "$1" || true; }
api() { curl -s -H "Authorization: Bearer $HL7EDGE_ADMIN_TOKEN" "http://localhost:8080/api/$1"; }
dead_letters() { api routes/lab-results-from-sftp/messages/dlq | grep -o '"seq":' | wc -l | tr -d ' '; }
wait_until() { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n - 1)); done; return 1; }
closed_batches() { lab_ls inbox | grep -c '^orders_.*\.hl7$' || true; }
# Conditions for wait_until.
ready() { curl -sf http://localhost:8080/ready >/dev/null; }
has_file() { docker compose exec -T sftp test -f "/home/hospital/$1"; }
meditech_count_is() { [ "$(docker compose logs meditech | grep -c "$2")" = "$1" ]; }
dead_letters_are() { [ "$(dead_letters)" = "$1" ]; }
batches_at_least() { [ "$(closed_batches)" -ge "$1" ]; }

step "Starting the lab's SFTP server, the gateway and a stand-in MEDITECH"
docker compose --progress quiet up -d
wait_until 60 ready || fail "the gateway is not ready; see: docker compose logs gateway"
docker compose logs keys | grep -A1 "host key:" | tail -1
echo "The gateway polls the lab's outbox every 5 s."

step "1. The lab drops an HL7 batch file with three results"
lab_drop results-batch.hl7
wait_until 30 meditech_count_is 3 'AA LAB-700[123]' || fail "MEDITECH should file LAB-7001 to LAB-7003"
meditech | grep "LAB-700[123]"
[ "$(meditech | grep -o 'LAB-700[123]' | tr '\n' ' ')" = "LAB-7001 LAB-7002 LAB-7003 " ] || fail "the results should arrive in file order"
wait_until 15 has_file outbox/processed/results-batch.hl7 || fail "the file should be moved to outbox/processed"
echo "Filed in order; results-batch.hl7 is now in outbox/processed."

step "2. A file with a stray line, and a result for a patient MEDITECH doesn't know"
lab_drop results-mixed.hl7
wait_until 30 has_file outbox/errors/results-mixed.hl7.txt || fail "the stray line should go to outbox/errors"
wait_until 30 meditech_count_is 2 'LAB-700[45]' || fail "MEDITECH should see LAB-7004 and LAB-7005"
meditech | grep "LAB-700[45]"
echo "outbox/errors/results-mixed.hl7.txt:"
lab_cat outbox/errors/results-mixed.hl7.txt
wait_until 10 dead_letters_are 1 || fail "LAB-7005 (AR from MEDITECH) should be in the gateway's dead letters"
echo "LAB-7005 is in the gateway's dead letters: see the console, http://localhost:8080."

step "3. MEDITECH sends orders; the gateway writes them to the lab's inbox as HL7 batch files"
send /messages/orm-o01-1.hl7 /messages/orm-o01-2.hl7 /messages/orm-o01-3.hl7
wait_until 30 batches_at_least 1 || fail "three orders should close a batch file"
first=$(lab_ls inbox | grep '^orders_' | head -1)
echo "inbox/$first:"
lab_cat "inbox/$first"
lab_cat "inbox/$first" | grep -q '^BTS|3$' || fail "the batch file should end with BTS|3"
send /messages/orm-o01-4.hl7
echo "One more order: its batch file is closed 20 s after it, by max_wait."
wait_until 45 batches_at_least 2 || fail "max_wait should close the second batch file"
lab_ls inbox

step "4. MEDITECH goes down; the lab's result waits in the gateway"
docker compose --progress quiet stop meditech
lab_drop result-single.hl7
wait_until 30 has_file outbox/processed/result-single.hl7 || fail "the file should be taken (the result is queued)"
echo "result-single.hl7 is processed: LAB-7006 is queued in the gateway. Waiting 10 s..."
sleep 10
docker compose --progress quiet start meditech
wait_until 45 meditech_count_is 1 'AA LAB-7006' || fail "LAB-7006 should be filed once MEDITECH is back"
echo "MEDITECH is back; LAB-7006 filed."

step "5. The lab's SFTP server goes down; orders wait in the gateway"
docker compose --progress quiet stop sftp
send /messages/orm-o01-5.hl7
echo "MEDITECH got AA. The console shows orders-to-lab-sftp retrying. Waiting 10 s..."
sleep 10
docker compose --progress quiet start sftp
wait_until 60 batches_at_least 3 || fail "ORD-8005 should reach the lab once its server is back"
lab_cat inbox/"$(lab_ls inbox | grep '^orders_' | tail -1)" | grep -q 'ORD-8005' || fail "the newest batch file should hold ORD-8005"
echo "The server is back; ORD-8005 is in a batch file in the inbox."

step "6. The host key the gateway trusts"
docker compose --progress quiet run --rm -T gateway-cli host-key --to sftp 2>/dev/null | head -1
echo "Matches the fingerprint the keys container printed at the start: the gateway refuses any other server."

echo
echo "Done. Results in order, a stray line set aside, orders batched, and both outages ridden out."
