#!/bin/sh
# Run by the SFTP server at startup (atmoz/sftp runs /etc/sftp.d/*): use the host keys from the keys
# volume, so known_hosts stays valid when the container is recreated, and let the gateway's key in.
set -eu
for k in ed25519 rsa; do
  cp "/keys/ssh_host_${k}_key" "/etc/ssh/ssh_host_${k}_key"
  cp "/keys/ssh_host_${k}_key.pub" "/etc/ssh/ssh_host_${k}_key.pub"
  chmod 600 "/etc/ssh/ssh_host_${k}_key"
done
mkdir -p /home/hospital/.ssh
grep -qsF "$(cat /keys/gateway_ed25519.pub)" /home/hospital/.ssh/authorized_keys ||
  cat /keys/gateway_ed25519.pub >> /home/hospital/.ssh/authorized_keys
chown -R 1001:100 /home/hospital/.ssh
chmod 700 /home/hospital/.ssh
chmod 600 /home/hospital/.ssh/authorized_keys
