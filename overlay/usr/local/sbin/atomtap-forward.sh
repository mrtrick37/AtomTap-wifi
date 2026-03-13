#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/atomtap/forward.env"
TUNNEL_IFACE="atomtap-erspan"
ERSPAN_ID="${ERSPAN_ID:-1}"
ERSPAN_VER="${ERSPAN_VER:-1}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/etc/atomtap/forward.env
  source "$ENV_FILE"
fi

ETH_IFACE="${ETH_IFACE:-eth0}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
COLLECTOR_IP="${COLLECTOR_IP:-}"

require_collector_ip() {
  if [[ -z "$COLLECTOR_IP" ]]; then
    echo "COLLECTOR_IP is required in $ENV_FILE" >&2
    exit 1
  fi
}

start_tap() {
  ip link set "$ETH_IFACE" promisc on up
  ip link set "$WIFI_IFACE" promisc on up

  # Remove any existing qdisc
  tc qdisc del dev "$ETH_IFACE" clsact 2>/dev/null || true
  tc qdisc add dev "$ETH_IFACE" clsact

  # Mirror all eth0 ingress and egress to the WiFi interface (unencapsulated SPAN)
  tc filter add dev "$ETH_IFACE" ingress protocol all pref 10 matchall \
    action mirred egress mirror dev "$WIFI_IFACE"

  tc filter add dev "$ETH_IFACE" egress protocol all pref 10 matchall \
    action mirred egress mirror dev "$WIFI_IFACE"

  echo "AtomTap: mirroring $ETH_IFACE → $WIFI_IFACE (unencapsulated SPAN)"

  exec sleep infinity
}

stop_tap() {
  tc qdisc del dev "$ETH_IFACE" clsact 2>/dev/null || true
  ip link set "$ETH_IFACE" promisc off 2>/dev/null || true
  ip link set "$WIFI_IFACE" promisc off 2>/dev/null || true
}

status_tap() {
  echo "==== SPAN Status ===="
  tc filter show dev "$ETH_IFACE" ingress 2>/dev/null || true
  tc filter show dev "$ETH_IFACE" egress 2>/dev/null || true
  echo "==== Interface Promiscuity ===="
  ip link show "$ETH_IFACE" | grep promisc || echo "$ETH_IFACE not promiscuous"
  ip link show "$WIFI_IFACE" | grep promisc || echo "$WIFI_IFACE not promiscuous"
}

case "${1:-start}" in
  start)   start_tap  ;;
  stop)    stop_tap   ;;
  restart) stop_tap; start_tap ;;
  status)  status_tap ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
