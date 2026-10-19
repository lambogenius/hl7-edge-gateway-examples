#!/bin/sh
# keepalived health check: this host may hold the VIP only while its gateway is ready
# (running, licensed config loaded, and the JetStream store reachable).
exec curl -sf -m 2 -o /dev/null http://127.0.0.1:8080/ready
