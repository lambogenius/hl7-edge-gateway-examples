#!/bin/sh
# Run once by the keys container: the lab SFTP server's host keys, the gateway's private key, and a
# known_hosts file with the server's keys, all in the keys volume. In production the lab sends you its
# host key fingerprint, and you give the lab your public key.
set -eu
[ -f /keys/known_hosts ] && { echo "keys already made"; exit 0; }
apk add --no-cache -q openssh-keygen
ssh-keygen -q -t ed25519 -N "" -C "lab sftp host key" -f /keys/ssh_host_ed25519_key
ssh-keygen -q -t rsa -b 3072 -N "" -C "lab sftp host key" -f /keys/ssh_host_rsa_key
ssh-keygen -q -t ed25519 -N "" -C "hl7-edge-gateway" -f /keys/gateway_ed25519
for k in ed25519 rsa; do echo "sftp $(cut -d' ' -f1,2 /keys/ssh_host_${k}_key.pub)"; done > /keys/known_hosts
# The gateway runs as its own user (uid 10001) and must read its key. On a real server, make the key
# file readable by that user only.
chmod 644 /keys/gateway_ed25519
echo "keys made; the SFTP server's host key:"
ssh-keygen -lf /keys/ssh_host_ed25519_key.pub
