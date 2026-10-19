# keepalived as it runs on edge1/edge2, for the test harness.
FROM alpine:3.20
RUN apk add --no-cache keepalived curl
COPY keepalived/check_gateway.sh /etc/keepalived/check_gateway.sh
RUN chmod 755 /etc/keepalived/check_gateway.sh
# keepalived refuses a configuration file that looks executable, as bind mounts from Windows do: copy it.
CMD ["sh", "-c", "rm -rf /run/keepalived && install -m 644 /config/keepalived.conf /etc/keepalived/keepalived.conf && exec keepalived --dont-fork --log-console --log-detail -f /etc/keepalived/keepalived.conf"]
