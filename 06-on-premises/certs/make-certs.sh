#!/usr/bin/env sh
# Makes a private CA and one certificate per host for NATS (server and cluster mutual TLS).
# Use your organization's CA instead if you have one; the certificates just need these names and
# addresses, and both serverAuth and clientAuth.
#   ./make-certs.sh                    writes ca.crt, ca.key, and edge1/ edge2/ edge3/ (server.crt, server.key)
set -eu
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep -subj "/CN=..." as it is
[ -f ca.crt ] || openssl req -x509 -newkey rsa:3072 -nodes -days 1825 -subj "/CN=HL7 Edge NATS CA" \
  -keyout ca.key -out ca.crt 2>/dev/null
for n in 1 2 3; do
  host=edge$n; mkdir -p "$host"
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$host" -keyout "$host/server.key" -out "$host/server.csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s,DNS:%s.hospital.local,IP:10.0.10.1%s\nextendedKeyUsage=serverAuth,clientAuth\n' "$host" "$host" "$n" > "$host/ext"
  openssl x509 -req -in "$host/server.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 -extfile "$host/ext" \
    -out "$host/server.crt" 2>/dev/null
  rm "$host/server.csr" "$host/ext"
  cp ca.crt "$host/ca.crt"
  echo "certs/$host: server.crt (edge$n, 10.0.10.1$n), server.key, ca.crt"
done
rm -f ca.srl
