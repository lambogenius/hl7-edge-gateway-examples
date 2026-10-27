#!/bin/sh
# Run by the keys container: the SFTP server's host keys, the gateway's private key, and a known_hosts file with
# the server's keys, all in the keys volume. In production, the server's owner (your file server team, or the
# clearinghouse) gives you its host key fingerprint, and you give them the gateway's public key.
# Also a self-signed certificate for the console on https://localhost:8080. Each is made once.
set -eu
if [ ! -f /keys/console.crt ]; then
  apk add --no-cache -q openssl
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 825 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" -keyout /keys/console.key -out /keys/console.crt 2>/dev/null
  chmod 644 /keys/console.key   # the gateway (uid 10001) reads it; on a real server, only that user should
  echo "console certificate made"
fi
[ -f /keys/known_hosts ] && { echo "keys already made"; exit 0; }
apk add --no-cache -q openssh-keygen
ssh-keygen -q -t ed25519 -N "" -C "sftp host key" -f /keys/ssh_host_ed25519_key
ssh-keygen -q -t rsa -b 3072 -N "" -C "sftp host key" -f /keys/ssh_host_rsa_key
ssh-keygen -q -t ed25519 -N "" -C "hl7-edge-gateway" -f /keys/gateway_ed25519
for k in ed25519 rsa; do echo "sftp $(cut -d' ' -f1,2 /keys/ssh_host_${k}_key.pub)"; done > /keys/known_hosts
# The gateway runs as its own user (uid 10001) and must read its key. On a real server, make the key file
# readable by that user only.
chmod 644 /keys/gateway_ed25519
echo "keys made; the SFTP server's host key:"
ssh-keygen -lf /keys/ssh_host_ed25519_key.pub
