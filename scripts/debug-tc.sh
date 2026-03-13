#!/usr/bin/env bash
# Debug script: Check tc filters and qdisc setup

ETH_IFACE="eth0"
TUNNEL_IFACE="atomtap-erspan"
ENV_FILE="/etc/atomtap/forward.env"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

echo "==== TC Qdisc ===="
tc qdisc show dev "$ETH_IFACE" 2>/dev/null || echo "No qdisc for $ETH_IFACE"

echo "==== TC Filters (Ingress) ===="
tc filter show dev "$ETH_IFACE" ingress 2>/dev/null || echo "No ingress filters for $ETH_IFACE"

echo "==== TC Filters (Egress) ===="
tc filter show dev "$ETH_IFACE" egress 2>/dev/null || echo "No egress filters for $ETH_IFACE"

exit 0
