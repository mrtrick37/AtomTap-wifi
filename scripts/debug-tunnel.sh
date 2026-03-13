#!/usr/bin/env bash
# Debug script: Check ERSPAN/GRE tunnel status

TUNNEL_IFACE="atomtap-erspan"
ETH_IFACE="eth0"
WIFI_IFACE="wlan0"
ENV_FILE="/etc/atomtap/forward.env"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

COLLECTOR_IP="${COLLECTOR_IP:-}"

echo "==== Tunnel Interface ===="
ip -d link show "$TUNNEL_IFACE" 2>/dev/null || echo "$TUNNEL_IFACE not present"

echo "==== Tunnel Route ===="
ip route show | grep "$COLLECTOR_IP" || echo "No route for collector IP ($COLLECTOR_IP)"

echo "==== Tunnel Link Status ===="
ip link show "$TUNNEL_IFACE" 2>/dev/null || echo "$TUNNEL_IFACE not present"

exit 0
